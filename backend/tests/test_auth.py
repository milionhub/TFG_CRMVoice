"""
AUTH (P0): registro, login, JWT, /me y protección de endpoints.

Notas de contrato:
- Los mensajes de error de /login NO se fijan (solo el 401): distinguen
  "usuario no encontrado" de "password incorrecto" (enumeración, B6) y está
  previsto unificarlos.
- Sin cabecera Authorization, HTTPBearer (FastAPI 0.124) responde 401
  "Not authenticated" con WWW-Authenticate: Bearer. Es el comportamiento real
  de la versión fijada en requirements; se protege tal cual.
"""
import os
import time
from datetime import timedelta

import pytest
from jose import jwt


# ---------------------------------------------------------------------
# REGISTER
# ---------------------------------------------------------------------

def test_register_crea_usuario_y_devuelve_token_utilizable(client, dbq):
    response = client.post("/register", json={
        "nombre": "Ana Nueva", "email": "ana.nueva@test.local", "password": "Secreta-123",
    })

    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["access_token"]

    stored = dbq.one("SELECT id, nombre, password_hash FROM salespeople WHERE email = ?",
                     ("ana.nueva@test.local",))
    assert stored["nombre"] == "Ana Nueva"
    assert stored["password_hash"] and stored["password_hash"] != "Secreta-123"

    me = client.get("/me", headers={"Authorization": f"Bearer {body['access_token']}"})
    assert me.status_code == 200
    assert me.json()["id"] == stored["id"]
    assert me.json()["email"] == "ana.nueva@test.local"
    assert me.json()["nombre"] == "Ana Nueva"


def test_register_y_despues_login_con_la_misma_password(client):
    client.post("/register", json={"nombre": "Ana", "email": "ana@test.local", "password": "Secreta-123"})

    response = client.post("/login", json={"email": "ana@test.local", "password": "Secreta-123"})

    assert response.status_code == 200


def test_register_email_duplicado_400_y_no_crea_otro_usuario(client, user_a, dbq):
    response = client.post("/register", json={
        "nombre": "Otro", "email": user_a["email"], "password": "Secreta-123",
    })

    assert response.status_code == 400
    assert response.json()["detail"] == "El email ya está registrado"
    assert dbq.one("SELECT COUNT(*) AS n FROM salespeople WHERE email = ?", (user_a["email"],))["n"] == 1


# ---------------------------------------------------------------------
# LOGIN
# ---------------------------------------------------------------------

def test_login_correcto_devuelve_token_y_usuario(client, user_a):
    response = client.post("/login", json={"email": user_a["email"], "password": user_a["password"]})

    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["user"] == {"id": user_a["id"], "nombre": user_a["nombre"], "email": user_a["email"]}

    me = client.get("/me", headers={"Authorization": f"Bearer {body['access_token']}"})
    assert me.status_code == 200
    assert me.json()["id"] == user_a["id"]


def test_login_password_incorrecta_401(client, user_a):
    response = client.post("/login", json={"email": user_a["email"], "password": "no-es-esta"})

    assert response.status_code == 401
    assert "access_token" not in response.json()


def test_login_usuario_inexistente_401(client):
    response = client.post("/login", json={"email": "nadie@test.local", "password": "loquesea"})

    assert response.status_code == 401
    assert "access_token" not in response.json()


def test_login_cuenta_google_sin_password_hash_401(client, make_user):
    google_user = make_user("google.user@test.local", with_password=False, google_id="google-sub-123")

    for password in ("", "cualquiera"):
        response = client.post("/login", json={"email": google_user["email"], "password": password})
        assert response.status_code == 401
        assert "access_token" not in response.json()


# ---------------------------------------------------------------------
# JWT / ME
# ---------------------------------------------------------------------

def test_me_con_token_valido(client, user_a):
    response = client.get("/me", headers=user_a["headers"])

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == user_a["id"]
    assert body["email"] == user_a["email"]
    assert body["nombre"] == user_a["nombre"]
    assert "password_hash" not in body


def test_me_devuelve_siempre_el_usuario_del_token(client, user_a, user_b):
    assert client.get("/me", headers=user_a["headers"]).json()["id"] == user_a["id"]
    assert client.get("/me", headers=user_b["headers"]).json()["id"] == user_b["id"]


def test_me_sin_token_401(client):
    response = client.get("/me")

    assert response.status_code == 401
    assert response.headers.get("www-authenticate") == "Bearer"


def test_me_token_mal_firmado_401(client, user_a, jwt_factory):
    forged = jwt_factory(user_a["id"], user_a["email"], secret="otra-clave-que-no-es-la-del-servidor-0123456789")

    response = client.get("/me", headers={"Authorization": f"Bearer {forged}"})

    assert response.status_code == 401


def test_me_token_expirado_401(client, user_a, jwt_factory):
    expired = jwt_factory(user_a["id"], user_a["email"], expires_in=timedelta(minutes=-5))

    response = client.get("/me", headers={"Authorization": f"Bearer {expired}"})

    assert response.status_code == 401


@pytest.mark.parametrize("endpoint", ["register", "login"])
def test_token_emitido_caduca_segun_access_token_expire_minutes(client, make_user, dbq, endpoint):
    """Token REAL emitido por el backend: firmado, con sub correcto y exp ≈ emisión + N minutos."""
    if endpoint == "register":
        credentials = {"nombre": "Nuevo", "email": "nuevo@test.local", "password": "Secreta-123"}
        issued_before = time.time()
        response = client.post("/register", json=credentials)
    else:
        user = make_user("existente@test.local")
        credentials = {"email": user["email"], "password": user["password"]}
        issued_before = time.time()
        response = client.post("/login", json=credentials)
    issued_after = time.time()
    assert response.status_code == 200

    # Se verifica con la clave y el algoritmo del backend (firma + exp)
    payload = jwt.decode(response.json()["access_token"], os.environ["SECRET_KEY"],
                         algorithms=[os.environ["ALGORITHM"]])

    expected_id = dbq.one("SELECT id FROM salespeople WHERE email = ?", (credentials["email"],))["id"]
    assert payload["sub"] == str(expected_id)
    assert "exp" in payload
    lifetime = int(os.environ["ACCESS_TOKEN_EXPIRE_MINUTES"]) * 60
    # exp es un entero en segundos: margen de 5 s para redondeos y lentitud del test
    assert issued_before + lifetime - 5 <= payload["exp"] <= issued_after + lifetime + 5


@pytest.mark.parametrize("authorization", [
    "Bearer no-es-un-jwt",
    "Bearer ",
    "Basic dXN1YXJpbzpwYXNz",
])
def test_me_cabecera_authorization_invalida_401(client, authorization):
    response = client.get("/me", headers={"Authorization": authorization})

    assert response.status_code == 401


# ---------------------------------------------------------------------
# PROTECCIÓN: ningún endpoint de datos responde sin un token válido
# ---------------------------------------------------------------------

PROTECTED_ENDPOINTS = [
    ("GET", "/me"),
    ("POST", "/process-text"),
    ("POST", "/process-audio"),
    ("GET", "/activities"),
    ("POST", "/activities"),
    ("PUT", "/activities/1"),
    ("DELETE", "/activities/1"),
    ("GET", "/products"),
    ("GET", "/clients"),
    ("GET", "/contacts"),
    ("GET", "/activity-types"),
    ("POST", "/semantic-search"),
    ("GET", "/client-context/1"),
    ("POST", "/prepare-meeting"),
    ("POST", "/chat"),
]


@pytest.mark.parametrize("method,path", PROTECTED_ENDPOINTS)
def test_endpoint_protegido_sin_token_401(client, method, path):
    response = client.request(method, path)

    assert response.status_code == 401


@pytest.mark.parametrize("method,path", PROTECTED_ENDPOINTS)
def test_endpoint_protegido_con_token_invalido_401(client, method, path, jwt_factory):
    forged = jwt_factory(1, "x@test.local", secret="otra-clave-que-no-es-la-del-servidor-0123456789")

    response = client.request(method, path, headers={"Authorization": f"Bearer {forged}"})

    assert response.status_code == 401


def test_endpoints_publicos_no_exigen_token(client):
    assert client.get("/").status_code == 200
    assert client.get("/ping").status_code == 200
