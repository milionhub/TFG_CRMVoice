"""Garantías de la propia infraestructura de tests: BD aislada, sin red, sin Whisper."""
import os
import socket
import subprocess
import sys
from pathlib import Path

import pytest
import requests

import conftest
import db
import main
from fastapi.testclient import TestClient
from services import openai_service, whisper_service
from services.openai_client import AIServiceError

BACKEND_DIR = Path(__file__).resolve().parent.parent
REAL_DB = BACKEND_DIR / "crm.db"


def test_la_bd_de_cada_test_es_temporal_y_no_es_crm_db(isolated_backend, client, dbq):
    assert Path(db.DB_PATH).resolve() == isolated_backend.resolve()
    assert Path(db.DB_PATH).resolve() != REAL_DB.resolve()

    # Una escritura real a través de la API cae en la BD temporal
    response = client.post("/register", json={
        "nombre": "Infra", "email": "infra@test.local", "password": "x" * 12,
    })
    assert response.status_code == 200
    assert dbq.one("SELECT email FROM salespeople WHERE email = ?", ("infra@test.local",))


def test_init_db_crea_esquema_y_tipos_de_actividad(dbq):
    tables = {r["name"] for r in dbq.all("SELECT name FROM sqlite_master WHERE type = 'table'")}
    assert {"salespeople", "clients", "contacts", "products", "activities",
            "activity_products", "activity_embeddings"} <= tables
    assert {r["accion"] for r in dbq.all("SELECT accion FROM activity_types")} == set(db.ACTIVITY_TYPES)


def test_cada_test_empieza_con_la_bd_vacia(dbq):
    assert dbq.one("SELECT COUNT(*) AS n FROM salespeople")["n"] == 0
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0


def test_ping(client):
    response = client.get("/ping")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_el_entorno_es_ficticio_y_env_real_no_se_lee():
    assert os.environ["SECRET_KEY"] == conftest.FAKE_SECRET_KEY
    assert os.environ["OPENAI_API_KEY"] == conftest.FAKE_OPENAI_KEY
    assert os.environ["OPENAI_BASE_URL"].startswith("http://127.0.0.1:")
    assert os.environ["GOOGLE_CLIENT_ID"] == ""
    import dotenv
    assert dotenv.load_dotenv() is False  # neutralizado


def test_importar_main_no_carga_whisper_ni_torch(tmp_path):
    """
    En un proceso limpio (sin las guardas de conftest) se comprueba el
    comportamiento real de producción: importar main no importa whisper/torch
    ni carga el modelo.
    """
    env = {**os.environ, "CRMVOICE_DB_PATH": str(tmp_path / "subprocess.db")}
    code = (
        "import sys, main; from services import whisper_service;"
        "print('whisper' in sys.modules, 'torch' in sys.modules, whisper_service._model is None)"
    )
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=BACKEND_DIR, env=env, capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.split()[-3:] == ["False", "False", "True"]


def test_en_esta_sesion_whisper_y_torch_no_estan_cargados():
    assert "whisper" not in sys.modules
    assert "torch" not in sys.modules
    assert whisper_service._model is None


def test_importar_whisper_o_torch_esta_prohibido_en_los_tests():
    with pytest.raises(ImportError):
        import whisper  # noqa: F401
    with pytest.raises(ImportError):
        import torch  # noqa: F401


def test_la_red_externa_esta_bloqueada():
    with pytest.raises(conftest.ExternalCallBlocked):
        socket.create_connection(("example.com", 443), timeout=1)
    with pytest.raises(conftest.ExternalCallBlocked):
        socket.socket().connect(("93.184.215.14", 443))
    with pytest.raises(requests.exceptions.ConnectionError):
        requests.get("https://oauth2.googleapis.com/tokeninfo", timeout=1)

    assert len(conftest.BLOCKED_NETWORK) >= 3
    conftest.BLOCKED_NETWORK.clear()  # intentos provocados a propósito


def test_openai_sin_mockear_falla_y_queda_registrado():
    # No sale ninguna petición: el cliente OpenAI está sustituido por un doble.
    # La capa IA convierte el bloqueo en AIServiceError, pero queda registrado.
    with pytest.raises(AIServiceError):
        openai_service.generate_embedding("hola")

    assert conftest.BLOCKED_OPENAI == ["services.openai_service.client.embeddings.create"]
    conftest.BLOCKED_OPENAI.clear()  # llamada provocada a propósito


# =====================================================================
# Arranque: la BD se inicializa en el lifespan, no al importar main
# =====================================================================

def test_importar_main_no_inicializa_la_bd_y_arrancar_la_app_si(tmp_path):
    """
    Proceso limpio: importar main no crea la SQLite; arrancar la aplicación
    (lifespan, como hace uvicorn) la crea con su esquema antes de atender.
    """
    db_file = tmp_path / "startup.db"
    env = {**os.environ, "CRMVOICE_DB_PATH": str(db_file)}
    code = (
        "import sqlite3; from pathlib import Path; import main;"
        "from fastapi.testclient import TestClient;"
        f"p = Path({str(db_file)!r}); print(p.exists());"
        "c = TestClient(main.app);"
        "c.__enter__(); print(p.exists());"
        "print(c.get('/ping').status_code);"
        "names = {r[0] for r in sqlite3.connect(p).execute(\"SELECT name FROM sqlite_master WHERE type='table'\")};"
        "print('salespeople' in names and 'activities' in names);"
        "c.__exit__(None, None, None)"
    )
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=BACKEND_DIR, env=env, capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.split()[-4:] == ["False", "True", "200", "True"]


def test_el_lifespan_inicializa_la_bd_configurada(tmp_path, monkeypatch):
    fresh = tmp_path / "lifespan.db"
    monkeypatch.setattr(db, "DB_PATH", fresh)

    TestClient(main.app)  # sin arrancar la app: no se toca la BD
    assert not fresh.exists()

    with TestClient(main.app) as client:
        assert fresh.exists()
        assert client.get("/ping").status_code == 200

    conn = db.get_connection()
    try:
        types = {r["accion"] for r in conn.execute("SELECT accion FROM activity_types")}
    finally:
        conn.close()
    assert types == set(db.ACTIVITY_TYPES)
