"""
D.5 — Login con Google (POST /auth/google).

Solo se sustituye la frontera oficial google.oauth2.id_token.verify_oauth2_token
(la que verifica firma, iss, exp y aud contra las claves públicas de Google).
Todo lo demás —configuración, validación de claims, búsqueda/creación del
comercial, conflictos y emisión del JWT— es el código real
(api/routers/auth.py y services/accounts.py).

Contrato actual (api/routers/auth.py: google_login):
  - GOOGLE_CLIENT_ID vacío/ausente          -> 503 "Login con Google no configurado"
  - idToken ausente/vacío/no string          -> 400 "Missing token"
  - verify lanza TransportError              -> 502 "No se pudo validar con Google"
  - verify lanza ValueError/GoogleAuthError  -> 401 "Invalid Google token"
  - azp presente y distinto del Client ID    -> 401 "Invalid Google token"
  - sin sub o sin email                      -> 401 "Invalid Google token"
  - email_verified distinto de True          -> 401 "Email de Google no verificado"
  - google_id conocido                       -> login en ESA cuenta
  - email ya usado (password u otra Google)  -> 409, sin vincular ni tocar nada
  - usuario nuevo                            -> se crea sin password_hash
  - 200 -> {"access_token", "user": {"id", "nombre", "email"}}
"""
import os
import time

import pytest
from google.auth import exceptions as google_exceptions
from google.oauth2 import id_token as google_id_token
from jose import jwt

import db
from services import accounts

CLIENT_ID = "test-client-id.apps.googleusercontent.com"
ID_TOKEN = "google-id-token-de-prueba.cabecera.firma"


# =====================================================================
# Doble de la frontera oficial de Google
# =====================================================================

class FakeVerifier:
    """Sustituye a google.oauth2.id_token.verify_oauth2_token."""

    def __init__(self):
        self.claims = None
        self.error = None
        self.calls = []

    def __call__(self, token, request, audience=None, clock_skew_in_seconds=0):
        self.calls.append({"token": token, "audience": audience, "clock_skew": clock_skew_in_seconds})
        if self.error is not None:
            raise self.error
        return dict(self.claims)


def google_claims(sub="google-sub-123", email="ana.google@test.local", **overrides):
    claims = {
        "iss": "https://accounts.google.com",
        "aud": CLIENT_ID,
        "azp": CLIENT_ID,
        "sub": sub,
        "email": email,
        "email_verified": True,
        "name": "Ana Google",
    }
    claims.update(overrides)
    return {k: v for k, v in claims.items() if v is not _DROP}


_DROP = object()  # google_claims(email=_DROP) -> el claim no existe


@pytest.fixture
def google(monkeypatch):
    monkeypatch.setenv("GOOGLE_CLIENT_ID", CLIENT_ID)
    verifier = FakeVerifier()
    verifier.claims = google_claims()
    # Frontera oficial: el router llama a google.oauth2.id_token.verify_oauth2_token
    monkeypatch.setattr(google_id_token, "verify_oauth2_token", verifier)
    return verifier


def google_login(client, token=ID_TOKEN):
    return client.post("/auth/google", json={"idToken": token})


def salespeople(dbq):
    return dbq.all("SELECT * FROM salespeople ORDER BY id")


def decode(token):
    return jwt.decode(token, os.environ["SECRET_KEY"], algorithms=[os.environ["ALGORITHM"]])


# =====================================================================
# D.5.1 Happy path
# =====================================================================

def test_usuario_nuevo_se_crea_sin_password_y_recibe_jwt_valido(client, google, dbq):
    before = time.time()
    response = google_login(client)
    after = time.time()

    assert response.status_code == 200
    rows = salespeople(dbq)
    assert len(rows) == 1
    user = rows[0]
    assert user["google_id"] == "google-sub-123"
    assert user["email"] == "ana.google@test.local"
    assert user["nombre"] == "Ana Google"
    assert user["password_hash"] is None

    body = response.json()
    assert set(body) == {"access_token", "user"}
    assert body["user"] == {"id": user["id"], "nombre": "Ana Google", "email": "ana.google@test.local"}

    payload = decode(body["access_token"])
    assert payload["sub"] == str(user["id"])
    assert payload["email"] == "ana.google@test.local"
    lifetime = int(os.environ["ACCESS_TOKEN_EXPIRE_MINUTES"]) * 60
    assert before + lifetime - 5 <= payload["exp"] <= after + lifetime + 5

    me = client.get("/me", headers={"Authorization": f"Bearer {body['access_token']}"})
    assert me.status_code == 200
    assert me.json()["id"] == user["id"]
    assert me.json()["email"] == "ana.google@test.local"


def test_se_verifica_el_token_recibido_contra_nuestro_client_id(client, google):
    google_login(client)

    assert google.calls == [{"token": ID_TOKEN, "audience": CLIENT_ID, "clock_skew": 10}]


def test_segundo_login_del_mismo_usuario_no_duplica(client, google, dbq):
    first = google_login(client).json()
    second = google_login(client)

    assert second.status_code == 200
    assert len(salespeople(dbq)) == 1
    assert second.json()["user"]["id"] == first["user"]["id"]
    assert decode(second.json()["access_token"])["sub"] == str(first["user"]["id"])


def test_sin_name_se_crea_con_nombre_vacio(client, google, dbq):
    google.claims = google_claims(name=_DROP)

    response = google_login(client)

    assert response.status_code == 200
    assert salespeople(dbq)[0]["nombre"] == ""


@pytest.mark.parametrize("azp", ["same", "absent"])
def test_azp_igual_al_client_id_o_ausente_se_acepta(client, google, azp):
    google.claims = google_claims(azp=CLIENT_ID if azp == "same" else _DROP)

    assert google_login(client).status_code == 200


# =====================================================================
# D.5.2 Validación del token y de la configuración
# =====================================================================

@pytest.mark.parametrize("body", [
    {},
    {"idToken": ""},
    {"idToken": None},
    {"idToken": 12345},
    {"idToken": ["a", "b"]},
    {"accessToken": "ya29.token-de-acceso-legacy"},  # el frontend antiguo enviaba esto
])
def test_id_token_ausente_vacio_o_no_texto_400_sin_llamar_a_google(client, google, dbq, body):
    response = client.post("/auth/google", json=body)

    assert response.status_code == 400
    assert response.json() == {"detail": "Missing token"}
    assert google.calls == []
    assert salespeople(dbq) == []


def test_body_que_no_es_un_objeto_422(client, google):
    assert client.post("/auth/google", json=["idToken"]).status_code == 422


@pytest.mark.parametrize("error", [
    ValueError("Token used too late, 1700000000 > 1690000000"),         # expirado
    ValueError("Token has wrong audience otro-cliente.apps.googleusercontent.com"),
    ValueError("Could not verify token signature."),
    google_exceptions.InvalidValue("Token has wrong issuer"),
    google_exceptions.RefreshError("error genérico de google-auth"),
    google_exceptions.GoogleAuthError("error genérico de google-auth"),
], ids=["expirado", "audience", "firma", "issuer", "refresh", "google_auth"])
def test_token_rechazado_por_google_auth_401(client, google, dbq, error):
    google.error = error

    response = google_login(client)

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid Google token"}
    assert salespeople(dbq) == []


def test_azp_distinto_de_nuestro_client_id_401(client, google, dbq):
    google.claims = google_claims(azp="otra-app.apps.googleusercontent.com")

    response = google_login(client)

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid Google token"}
    assert salespeople(dbq) == []


@pytest.mark.parametrize("claim,value", [
    ("sub", _DROP), ("sub", ""), ("sub", None),
    ("email", _DROP), ("email", ""), ("email", None),
])
def test_sin_sub_o_sin_email_401(client, google, dbq, claim, value):
    google.claims = google_claims(**{claim: value})

    response = google_login(client)

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid Google token"}
    assert salespeople(dbq) == []


@pytest.mark.parametrize("email_verified", [False, _DROP, None, "true", 1])
def test_email_no_verificado_401(client, google, dbq, email_verified):
    # Solo el booleano True es válido (Google lo envía así en el ID token)
    google.claims = google_claims(email_verified=email_verified)

    response = google_login(client)

    assert response.status_code == 401
    assert response.json() == {"detail": "Email de Google no verificado"}
    assert salespeople(dbq) == []


@pytest.mark.parametrize("configured", ["absent", "empty"])
def test_sin_google_client_id_503_sin_llamar_a_google(client, google, monkeypatch, dbq, configured):
    if configured == "absent":
        monkeypatch.delenv("GOOGLE_CLIENT_ID")
    else:
        monkeypatch.setenv("GOOGLE_CLIENT_ID", "")

    response = google_login(client)

    assert response.status_code == 503
    assert response.json() == {"detail": "Login con Google no configurado"}
    assert google.calls == []
    assert salespeople(dbq) == []


# =====================================================================
# D.5.3 Conflictos / vinculación de cuentas (snapshot antes/después)
# =====================================================================

def test_a_email_de_cuenta_con_password_409_sin_vincular(client, google, make_user, dbq):
    owner = make_user("ana.google@test.local", "Ana Password")
    before = salespeople(dbq)

    response = google_login(client)

    assert response.status_code == 409
    assert response.json() == {"detail": "Este email ya tiene una cuenta en CRMVoice. Inicia sesión con tu contraseña."}
    assert "access_token" not in response.json()
    assert salespeople(dbq) == before  # google_id sigue NULL, hash intacto, sin filas nuevas
    # La cuenta con password sigue funcionando con su contraseña
    assert client.post("/login", json={"email": owner["email"], "password": owner["password"]}).status_code == 200


def test_b_cuenta_google_existente_hace_login_normal(client, google, make_user, dbq):
    existing = make_user("ana.google@test.local", "Ana Google", with_password=False, google_id="google-sub-123")
    before = salespeople(dbq)

    response = google_login(client)

    assert response.status_code == 200
    assert response.json()["user"]["id"] == existing["id"]
    assert decode(response.json()["access_token"])["sub"] == str(existing["id"])
    assert salespeople(dbq) == before


def test_c_google_id_conocido_con_email_cambiado_entra_en_su_cuenta_sin_mutarla(client, google, make_user, dbq):
    """
    Política actual: manda el google_id (sub). El email del token no se usa para
    elegir cuenta ni se escribe en BD: aunque el nuevo email pertenezca a OTRA
    cuenta, se entra en la cuenta del google_id (no hay account takeover).
    """
    own = make_user("antiguo@test.local", "Ana Google", with_password=False, google_id="google-sub-123")
    victim = make_user("victima@test.local", "Víctima")
    google.claims = google_claims(email="victima@test.local")
    before = salespeople(dbq)

    response = google_login(client)

    assert response.status_code == 200
    body = response.json()
    assert body["user"]["id"] == own["id"]
    assert body["user"]["email"] == "antiguo@test.local"
    payload = decode(body["access_token"])
    assert payload["sub"] == str(own["id"]) != str(victim["id"])
    assert payload["email"] == "antiguo@test.local"
    assert salespeople(dbq) == before


def test_d_email_de_otra_cuenta_google_409_sin_sobrescribir_google_id(client, google, make_user, dbq):
    make_user("ana.google@test.local", "Ana", with_password=False, google_id="otro-google-sub-999")
    before = salespeople(dbq)

    response = google_login(client)  # sub = google-sub-123, mismo email

    assert response.status_code == 409
    assert response.json() == {"detail": "El email ya está asociado a otra cuenta de Google"}
    assert salespeople(dbq) == before


# ---------------------------------------------------------------------
# E) Conflicto simultáneo: otra petición crea la cuenta entre el SELECT y el INSERT
# ---------------------------------------------------------------------

class _RacingCursor:
    def __init__(self, cursor, on_insert):
        self._cursor = cursor
        self._on_insert = on_insert

    def execute(self, sql, params=()):
        if "INSERT INTO salespeople" in sql and self._on_insert:
            self._on_insert()
            self._on_insert = None
        return self._cursor.execute(sql, params)

    def __getattr__(self, name):
        return getattr(self._cursor, name)


class _RacingConnection:
    def __init__(self, conn, on_insert):
        self._conn = conn
        self._on_insert = on_insert

    def cursor(self):
        return _RacingCursor(self._conn.cursor(), self._on_insert)

    def __getattr__(self, name):
        return getattr(self._conn, name)


@pytest.fixture(params=["mismo_google_id", "mismo_email"])
def racing_insert(request, monkeypatch):
    """Simula otra petición que inserta la cuenta justo antes de nuestro INSERT."""
    def concurrent_insert():
        other = db.get_connection()
        if request.param == "mismo_google_id":
            other.execute("INSERT INTO salespeople (nombre, email, google_id) VALUES (?, ?, ?)",
                          ("Ana Google", "ana.google@test.local", "google-sub-123"))
        else:
            other.execute("INSERT INTO salespeople (nombre, email, google_id) VALUES (?, ?, ?)",
                          ("Otra", "ana.google@test.local", "otro-google-sub-999"))
        other.commit()
        other.close()

    real_get_connection = accounts.get_connection
    # El servicio de cuentas usa su referencia a get_connection: se parchea ahí
    monkeypatch.setattr(accounts, "get_connection",
                        lambda: _RacingConnection(real_get_connection(), concurrent_insert))
    return request.param


def test_e_conflicto_simultaneo_no_duplica_ni_muta(client_no_raise, google, racing_insert, dbq):
    client_no_raise.post("/auth/google", json={"idToken": ID_TOKEN})

    rows = salespeople(dbq)
    assert len(rows) == 1  # solo la fila de la "otra petición"
    expected_sub = "google-sub-123" if racing_insert == "mismo_google_id" else "otro-google-sub-999"
    assert rows[0]["google_id"] == expected_sub
    assert rows[0]["password_hash"] is None


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B15: la carrera SELECT->INSERT termina en IntegrityError no controlado (500)")
def test_b15_conflicto_simultaneo_responde_de_forma_controlada(client_no_raise, google, racing_insert):
    response = client_no_raise.post("/auth/google", json={"idToken": ID_TOKEN})

    # Deseado: login en la cuenta recién creada (mismo google_id) o 409 (email de otra cuenta)
    assert response.status_code in (200, 409)


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B16: el email se compara distinguiendo mayúsculas: se crea una 2ª cuenta")
def test_b16_email_con_distintas_mayusculas_es_la_misma_cuenta(client, google, make_user, dbq):
    make_user("Ana.Google@Test.Local", "Ana Password")

    response = google_login(client)  # email del token: ana.google@test.local

    assert response.status_code == 409
    assert len(salespeople(dbq)) == 1


# =====================================================================
# D.5.4 Errores de Google (infraestructura)
# =====================================================================

def test_error_de_transporte_con_google_502(client, google, dbq):
    google.error = google_exceptions.TransportError("No se pudo conectar con www.googleapis.com")

    response = google_login(client)

    assert response.status_code == 502
    assert response.json() == {"detail": "No se pudo validar con Google"}
    assert salespeople(dbq) == []


def test_excepcion_inesperada_500_generico_sin_detalles(client_no_raise, google, dbq):
    # Fuera del contrato (verify solo lanza ValueError/GoogleAuthError): 500 genérico
    google.error = RuntimeError(f"fallo interno con {ID_TOKEN}")

    response = client_no_raise.post("/auth/google", json={"idToken": ID_TOKEN})

    assert response.status_code == 500
    assert response.text == "Internal Server Error"
    assert salespeople(dbq) == []


# =====================================================================
# D.5.5 Respuestas de error: sin trazas, tokens ni detalles internos
# =====================================================================

ERROR_SCENARIOS = {
    "token_invalido": dict(error=ValueError(f"Wrong recipient, token {ID_TOKEN} for {CLIENT_ID}")),
    "transporte": dict(error=google_exceptions.TransportError(f"https://oauth2.googleapis.com/tokeninfo?id_token={ID_TOKEN}")),
    "azp": dict(claims=google_claims(azp="otra-app")),
    "sin_email": dict(claims=google_claims(email=_DROP)),
    "no_verificado": dict(claims=google_claims(email_verified=False)),
}


@pytest.mark.parametrize("scenario", ERROR_SCENARIOS)
def test_errores_no_filtran_token_trazas_ni_detalles(client, google, scenario):
    setup = ERROR_SCENARIOS[scenario]
    google.error = setup.get("error")
    if "claims" in setup:
        google.claims = setup["claims"]

    response = google_login(client)

    assert 400 <= response.status_code < 600
    text = response.text
    assert ID_TOKEN not in text
    assert CLIENT_ID not in text
    assert "Traceback" not in text and "File \"" not in text
    assert "googleapis" not in text
    assert set(response.json()) == {"detail"}
