"""
Infraestructura común de los tests del backend.

Garantías (en este orden, ANTES de importar ningún módulo del backend):
  1. Se toma una "foto" de backend/crm.db para comprobar al final que no cambió.
  2. Entorno ficticio: SECRET_KEY/OPENAI_API_KEY falsas, OPENAI_BASE_URL a un
     puerto muerto de loopback y GOOGLE_CLIENT_ID vacío. load_dotenv() se
     neutraliza: el backend/.env real nunca se lee.
  3. CRMVOICE_DB_PATH apunta a una SQLite temporal (la que usa init_db() al
     importar main). Cada test usa además su propia SQLite nueva.
  4. Red bloqueada salvo loopback, e imports de whisper/torch prohibidos.

Durante cada test:
  - los clientes OpenAI de los módulos se sustituyen por uno que falla y
    registra cualquier uso (los tests mockean las funciones donde se usan);
  - cualquier intento de red externa o de uso de OpenAI hace fallar el test,
    aunque el código de producción capture la excepción;
  - la memoria del chat (chat_memory) empieza vacía.
"""
import hashlib
import importlib.abc
import json
import os
import shutil
import socket
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

BACKEND_DIR = Path(__file__).resolve().parent.parent
REAL_DB = BACKEND_DIR / "crm.db"


# =====================================================================
# 1. Foto de backend/crm.db (y sus ficheros -journal/-wal/-shm)
# =====================================================================

def _real_db_snapshot():
    snapshot = {}
    for path in sorted(BACKEND_DIR.glob("crm.db*")):
        snapshot[path.name] = (
            path.stat().st_mtime_ns,
            hashlib.sha256(path.read_bytes()).hexdigest(),
        )
    return snapshot


REAL_DB_SNAPSHOT = _real_db_snapshot()


# =====================================================================
# 2. Entorno ficticio (se sobrescribe cualquier valor real del shell)
# =====================================================================

FAKE_SECRET_KEY = "test-secret-key-not-for-production-0123456789abcdef"
FAKE_OPENAI_KEY = "sk-test-not-a-real-key"
DEAD_OPENAI_URL = "http://127.0.0.1:9/v1"  # puerto 9 (discard): nada escucha

os.environ.update({
    "SECRET_KEY": FAKE_SECRET_KEY,
    "ALGORITHM": "HS256",
    "ACCESS_TOKEN_EXPIRE_MINUTES": "60",
    "OPENAI_API_KEY": FAKE_OPENAI_KEY,
    "OPENAI_BASE_URL": DEAD_OPENAI_URL,
    # Vacío (no ausente): load_dotenv no lo rellenaría y /auth/google → 503
    "GOOGLE_CLIENT_ID": "",
})

# config.py llama a load_dotenv() al importarse: se neutraliza
# para que el backend/.env real no aporte ninguna variable a los tests.
import dotenv  # noqa: E402

dotenv.load_dotenv = lambda *args, **kwargs: False

# =====================================================================
# 3. SQLite temporal para el init_db() que main ejecuta al importarse
# =====================================================================

SESSION_DB_DIR = Path(tempfile.mkdtemp(prefix="crmvoice-tests-"))
os.environ["CRMVOICE_DB_PATH"] = str(SESSION_DB_DIR / "import_time.db")


# =====================================================================
# 4. Guardas: red externa e imports pesados
# =====================================================================

class ExternalCallBlocked(ConnectionError):
    """
    Un test ha intentado salir a la red o usar un servicio externo real.
    Hereda de ConnectionError (OSError) para que requests/httpx/google-auth lo
    traten como un fallo de red normal.
    """


# Intentos bloqueados durante el test en curso (se revisan en el teardown)
BLOCKED_NETWORK = []
BLOCKED_OPENAI = []

_LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}


def _is_loopback(host):
    if isinstance(host, bytes):
        host = host.decode(errors="ignore")
    if host is None:
        return True  # getaddrinfo(None, ...) = direcciones locales
    host = str(host)
    return host in _LOOPBACK_HOSTS or host.startswith("127.")


_original_connect = socket.socket.connect
_original_connect_ex = socket.socket.connect_ex
_original_getaddrinfo = socket.getaddrinfo


def _check_address(address):
    host = address[0] if isinstance(address, tuple) else None
    if isinstance(address, tuple) and not _is_loopback(host):
        BLOCKED_NETWORK.append(repr(address))
        raise ExternalCallBlocked(f"Conexión de red externa bloqueada en tests: {address!r}")


def _guarded_connect(self, address):
    _check_address(address)
    return _original_connect(self, address)


def _guarded_connect_ex(self, address):
    _check_address(address)
    return _original_connect_ex(self, address)


def _guarded_getaddrinfo(host, *args, **kwargs):
    if not _is_loopback(host):
        BLOCKED_NETWORK.append(f"DNS {host!r}")
        raise ExternalCallBlocked(f"Resolución DNS externa bloqueada en tests: {host!r}")
    return _original_getaddrinfo(host, *args, **kwargs)


socket.socket.connect = _guarded_connect
socket.socket.connect_ex = _guarded_connect_ex
socket.getaddrinfo = _guarded_getaddrinfo


class _BlockHeavyImports(importlib.abc.MetaPathFinder):
    """Whisper y PyTorch no deben importarse nunca en los tests."""

    BLOCKED = {"whisper", "torch"}

    def find_spec(self, fullname, path=None, target=None):
        if fullname.split(".")[0] in self.BLOCKED:
            raise ImportError(f"'{fullname}' no debe importarse en los tests (usa un doble de prueba)")
        return None


sys.meta_path.insert(0, _BlockHeavyImports())


# =====================================================================
# Importación del backend (ya con todas las guardas activas)
# =====================================================================

sys.path.insert(0, str(BACKEND_DIR))

import db  # noqa: E402

assert Path(db.DB_PATH).resolve() != REAL_DB.resolve(), "CRMVOICE_DB_PATH apunta a backend/crm.db"

import ai_router  # noqa: E402
import chat_memory  # noqa: E402
import main  # noqa: E402
import openai_service  # noqa: E402
import semantic_search_service  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from jose import jwt  # noqa: E402
from core.security import create_access_token, hash_password  # noqa: E402


# =====================================================================
# Fixtures de sesión
# =====================================================================

@pytest.fixture(scope="session", autouse=True)
def real_db_untouched():
    """Falla la suite si backend/crm.db (o sus -journal/-wal/-shm) cambia."""
    yield
    shutil.rmtree(SESSION_DB_DIR, ignore_errors=True)
    assert _real_db_snapshot() == REAL_DB_SNAPSHOT, "¡Los tests han modificado backend/crm.db!"


TEST_PASSWORD = "Contraseña-de-prueba-123"


@pytest.fixture(scope="session")
def password_hash():
    """Hash bcrypt de TEST_PASSWORD, calculado una sola vez (bcrypt es lento)."""
    return hash_password(TEST_PASSWORD)


# =====================================================================
# Fixtures por test: aislamiento
# =====================================================================

class _ForbiddenOpenAIClient:
    """Sustituye a los clientes OpenAI: cualquier llamada falla y queda registrada."""

    def __init__(self, path="client"):
        self._path = path

    def __getattr__(self, name):
        return _ForbiddenOpenAIClient(f"{self._path}.{name}")

    def __call__(self, *args, **kwargs):
        BLOCKED_OPENAI.append(self._path)
        raise ExternalCallBlocked(f"Llamada a OpenAI sin mockear: {self._path}(...)")


@pytest.fixture(autouse=True)
def isolated_backend(tmp_path, monkeypatch):
    """SQLite nueva por test, OpenAI prohibido, chat_memory vacía y cero red."""
    test_db = tmp_path / "test.db"
    assert test_db.resolve() != REAL_DB.resolve()
    monkeypatch.setattr(db, "DB_PATH", test_db)
    monkeypatch.setenv("CRMVOICE_DB_PATH", str(test_db))
    db.init_db()

    for module in (openai_service, ai_router, semantic_search_service):
        monkeypatch.setattr(module, "client", _ForbiddenOpenAIClient(f"{module.__name__}.client"))

    chat_memory._last_client_by_user.clear()
    chat_memory._pending_intent_by_user.clear()
    BLOCKED_NETWORK.clear()
    BLOCKED_OPENAI.clear()

    yield test_db

    chat_memory._last_client_by_user.clear()
    chat_memory._pending_intent_by_user.clear()
    # Aunque producción capture la excepción (p. ej. el embedding en
    # create/update), el intento hace fallar el test.
    assert not BLOCKED_NETWORK, f"Intentos de red externa: {BLOCKED_NETWORK}"
    assert not BLOCKED_OPENAI, f"Llamadas a OpenAI sin mockear: {BLOCKED_OPENAI}"


@pytest.fixture
def client():
    return TestClient(main.app)


@pytest.fixture
def client_no_raise():
    """TestClient que devuelve 500 en vez de propagar la excepción del servidor."""
    return TestClient(main.app, raise_server_exceptions=False)


# =====================================================================
# Usuarios y JWT
# =====================================================================

def make_token(user_id, email, *, secret=FAKE_SECRET_KEY, expires_in=timedelta(minutes=60)):
    """JWT con el mismo formato que emite el backend (sub = id en texto)."""
    payload = {
        "sub": str(user_id),
        "email": email,
        "exp": datetime.now(timezone.utc) + expires_in,
    }
    return jwt.encode(payload, secret, algorithm="HS256")


def auth_headers(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def jwt_factory():
    """make_token(user_id, email, secret=..., expires_in=...) para tokens a medida."""
    return make_token


@pytest.fixture
def make_user(password_hash):
    """Crea un comercial directamente en la BD y devuelve sus datos + token."""

    def _make_user(email, nombre="Comercial de prueba", *, with_password=True, google_id=None):
        conn = db.get_connection()
        cur = conn.execute(
            "INSERT INTO salespeople (nombre, email, password_hash, google_id) VALUES (?, ?, ?, ?)",
            (nombre, email, password_hash if with_password else None, google_id),
        )
        conn.commit()
        user_id = cur.lastrowid
        conn.close()

        token = create_access_token({"sub": str(user_id), "email": email})
        return {
            "id": user_id,
            "nombre": nombre,
            "email": email,
            "password": TEST_PASSWORD if with_password else None,
            "token": token,
            "headers": auth_headers(token),
        }

    return _make_user


@pytest.fixture
def user_a(make_user):
    return make_user("usuario.a@test.local", "Usuario A")


@pytest.fixture
def user_b(make_user):
    return make_user("usuario.b@test.local", "Usuario B")


# =====================================================================
# Factorías de catálogo y actividades (SQL directo, deterministas)
# =====================================================================

class Factory:
    """Inserta datos mínimos en la SQLite del test y devuelve sus ids."""

    def _insert(self, sql, params):
        conn = db.get_connection()
        cur = conn.execute(sql, params)
        conn.commit()
        row_id = cur.lastrowid
        conn.close()
        return row_id

    def client(self, razon_social="Cliente Prueba S.L.", alias=None):
        return self._insert("INSERT INTO clients (razon_social, alias) VALUES (?, ?)", (razon_social, alias))

    def contact(self, client_id, nombre="Contacto Prueba"):
        return self._insert("INSERT INTO contacts (client_id, nombre) VALUES (?, ?)", (client_id, nombre))

    def product(self, nombre="Producto Prueba", precio=100.0, aliases=()):
        product_id = self._insert("INSERT INTO products (nombre, precio) VALUES (?, ?)", (nombre, precio))
        for alias in aliases:
            self._insert("INSERT INTO product_aliases (product_id, alias) VALUES (?, ?)", (product_id, alias))
        return product_id

    def activity_type_id(self, accion="Concertar reunión"):
        conn = db.get_connection()
        row = conn.execute("SELECT id FROM activity_types WHERE accion = ?", (accion,)).fetchone()
        conn.close()
        return row["id"]

    def activity(self, owner_id, client_id, *, contact_id=None, activity_type_id=None,
                 datetime_iso="2026-10-01T10:00:00", comentario="Comentario de prueba",
                 products=(), embedding=None):
        """products: [(product_id, product_raw), ...]; embedding: lista de floats."""
        if activity_type_id is None:
            activity_type_id = self.activity_type_id()
        activity_id = self._insert(
            """
            INSERT INTO activities (datetime_iso, client_id, contact_id, activity_type_id,
                                    comentario, transcripcion, salesperson_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (datetime_iso, client_id, contact_id, activity_type_id, comentario, comentario, owner_id),
        )
        for product_id, product_raw in products:
            self._insert(
                "INSERT INTO activity_products (activity_id, product_id, product_raw, confidence_score) "
                "VALUES (?, ?, ?, ?)",
                (activity_id, product_id, product_raw, 100),
            )
        if embedding is not None:
            self._insert(
                "INSERT INTO activity_embeddings (activity_id, embedding_vector, embedding_model, content_type) "
                "VALUES (?, ?, ?, ?)",
                (activity_id, json.dumps(embedding), "text-embedding-3-small", "activity_full"),
            )
        return activity_id


@pytest.fixture
def factory():
    return Factory()


# =====================================================================
# Lectura directa de la BD del test
# =====================================================================

class DbReader:
    def all(self, sql, params=()):
        conn = db.get_connection()
        rows = [dict(r) for r in conn.execute(sql, params).fetchall()]
        conn.close()
        return rows

    def one(self, sql, params=()):
        rows = self.all(sql, params)
        return rows[0] if rows else None

    def activity(self, activity_id):
        return self.one("SELECT * FROM activities WHERE id = ?", (activity_id,))

    def activity_products(self, activity_id):
        return self.all(
            "SELECT product_id, product_raw FROM activity_products WHERE activity_id = ? ORDER BY product_id",
            (activity_id,),
        )

    def embeddings(self, activity_id):
        return self.all(
            "SELECT embedding_vector, embedding_model, content_type, created_at "
            "FROM activity_embeddings WHERE activity_id = ?",
            (activity_id,),
        )


@pytest.fixture
def dbq():
    return DbReader()


# =====================================================================
# Dobles de OpenAI (se parchean donde se usan: en main)
# =====================================================================

class FakeEmbedding:
    """Sustituye a main.generate_embedding: vector determinista y registro de llamadas."""

    def __init__(self, vector=None, error=None):
        self.vector = vector if vector is not None else [0.1, 0.2, 0.3]
        self.error = error
        self.calls = []

    def __call__(self, text):
        self.calls.append(text)
        if self.error is not None:
            raise self.error
        return list(self.vector)


@pytest.fixture
def fake_embedding(monkeypatch):
    """Embedding que funciona. Desactiva además la comprobación de duplicados (B2)."""
    fake = FakeEmbedding()
    monkeypatch.setattr(main, "generate_embedding", fake)
    # main importa is_duplicate_activity de openai_service dentro de la función:
    # se parchea en openai_service para que estos tests no dependan de B2.
    monkeypatch.setattr(openai_service, "is_duplicate_activity", lambda *args, **kwargs: (False, 0))
    return fake


@pytest.fixture
def failing_embedding(monkeypatch):
    fake = FakeEmbedding(error=RuntimeError("OpenAI no disponible (simulado)"))
    monkeypatch.setattr(main, "generate_embedding", fake)
    return fake
