"""
Configuración del backend leída del entorno.

backend/.env se carga una sola vez, al importar este módulo. Los valores se
leen en cada llamada (no se cachean): así un cambio de entorno, como los que
hacen los tests con monkeypatch.setenv, se aplica sin reiniciar.

La validación de las variables obligatorias está en env_check.py.
CRMVOICE_DB_PATH se lee en db.py y OPENAI_API_KEY en services/openai_client.py.
"""
import os

from dotenv import load_dotenv

load_dotenv()


# --- JWT de CRMVoice ---

def secret_key() -> str | None:
    return os.getenv("SECRET_KEY")


def jwt_algorithm() -> str | None:
    return os.getenv("ALGORITHM")


def access_token_expire_minutes() -> int:
    return int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES"))


# --- Login con Google ---

def google_client_id() -> str | None:
    """OAuth Client ID (público): audience esperada del ID token. Vacío = deshabilitado."""
    return os.getenv("GOOGLE_CLIENT_ID")


# --- CORS ---

def cors_origins() -> list[str]:
    """Orígenes permitidos, separados por comas en CORS_ORIGINS. Por defecto, todos ("*")."""
    raw = os.getenv("CORS_ORIGINS", "")
    origins = [origin.strip() for origin in raw.split(",") if origin.strip()]
    return origins or ["*"]
