"""Autenticación: login/registro con contraseña, /me y login con Google."""
import logging
from functools import lru_cache

from fastapi import APIRouter, Depends, HTTPException
from google.auth import exceptions as google_auth_exceptions
from google.auth.transport import requests as google_auth_requests
from google.oauth2 import id_token

import config
from api.deps import get_current_user
from core.security import create_access_token, hash_password, verify_password
from schemas.auth import LoginRequest, RegisterRequest
from services import accounts

logger = logging.getLogger("crmvoice")

router = APIRouter(tags=["auth"])


# Mismo 401 y mismo mensaje si el email no existe, si la cuenta es solo de
# Google o si la contraseña no coincide (B6: sin enumeración de usuarios)
INVALID_CREDENTIALS = "Email o contraseña incorrectos"


@lru_cache(maxsize=1)
def _dummy_password_hash() -> str:
    # Se verifica contra este hash cuando no hay uno real, para que el tiempo
    # de respuesta no delate si el email existe
    return hash_password("crmvoice-dummy-password-sin-cuenta")


def _password_matches(password: str, stored_hash: str | None, user_id=None) -> bool:
    if not stored_hash:
        verify_password(password, _dummy_password_hash())
        return False

    try:
        return verify_password(password, stored_hash)
    except Exception:
        logger.exception("Hash de contraseña no válido para el usuario %s", user_id)
        return False


@router.post("/login")
def login(request: LoginRequest):

    user = accounts.find_by_email(request.email)

    # Sin cuenta, o cuenta creada con Google (sin password_hash): nunca coincide
    stored_hash = user[3] if user else None

    if not _password_matches(request.password, stored_hash, user[0] if user else None):
        raise HTTPException(status_code=401, detail=INVALID_CREDENTIALS)

    user_id = user[0]
    nombre = user[1]
    user_email = user[2]

    token = create_access_token({
        "sub": str(user_id),
        "email": user_email
    })

    return {
        "access_token": token,
        "token_type": "bearer",
        "user": {
            "id": user_id,
            "nombre": nombre,
            "email": user_email
        }
    }


@router.post("/register")
def register(request: RegisterRequest):

    email = accounts.normalize_email(request.email)
    email_registered = HTTPException(status_code=400, detail="El email ya está registrado")

    if accounts.email_exists(email):
        raise email_registered

    password_hash = hash_password(request.password)

    try:
        user_id = accounts.create_password_account(request.nombre, email, password_hash)
    except accounts.EmailAlreadyRegistered:
        raise email_registered

    # Crear token automáticamente
    token = create_access_token({
        "sub": str(user_id),
        "email": email
    })

    return {
        "access_token": token,
        "token_type": "bearer"
    }


@router.get("/me")
def get_me(current_user=Depends(get_current_user)):

    user_id = int(current_user.get("user_id")) or current_user.get("sub")
    user_id = int(user_id)  # Asegurar que es int

    user = accounts.get_profile(user_id)

    if not user:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")

    return {
        "id": user[0],
        "nombre": user[1],
        "email": user[2],
        "created_at": user[3]
    }


@router.post("/auth/google")
def google_login(data: dict):

    # Client ID de la app web (público, no secreto): define la audience esperada
    google_client_id = config.google_client_id()

    if not google_client_id:
        logger.error("GOOGLE_CLIENT_ID no configurado: login con Google deshabilitado")
        raise HTTPException(status_code=503, detail="Login con Google no configurado")

    raw_id_token = data.get("idToken")

    if not raw_id_token or not isinstance(raw_id_token, str):
        raise HTTPException(status_code=400, detail="Missing token")

    # Verificación local del ID token: firma (claves públicas de Google),
    # iss, exp/iat y aud == nuestro Client ID
    try:
        idinfo = id_token.verify_oauth2_token(
            raw_id_token,
            google_auth_requests.Request(),
            audience=google_client_id,
            clock_skew_in_seconds=10,
        )
    except google_auth_exceptions.TransportError:
        logger.exception("Error obteniendo las claves públicas de Google")
        raise HTTPException(status_code=502, detail="No se pudo validar con Google")
    except (ValueError, google_auth_exceptions.GoogleAuthError):
        raise HTTPException(status_code=401, detail="Invalid Google token")

    # azp (authorized party), si viene, también debe ser nuestra app
    azp = idinfo.get("azp")
    if azp is not None and azp != google_client_id:
        raise HTTPException(status_code=401, detail="Invalid Google token")

    google_id = idinfo.get("sub")
    email = idinfo.get("email")
    name = idinfo.get("name", "")

    if not google_id or not email:
        raise HTTPException(status_code=401, detail="Invalid Google token")

    if idinfo.get("email_verified") is not True:
        raise HTTPException(status_code=401, detail="Email de Google no verificado")

    try:
        user = accounts.get_or_create_google_account(google_id, email, name)
    except accounts.AccountConflict as conflict:
        raise HTTPException(status_code=409, detail=str(conflict))

    jwt_token = create_access_token({
        "sub": str(user["id"]),
        "email": user["email"]
    })

    return {
        "access_token": jwt_token,
        "token_type": "bearer",
        "user": {
            "id": user["id"],
            "nombre": user["nombre"],
            "email": user["email"]
        }
    }
