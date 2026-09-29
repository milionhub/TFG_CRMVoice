import os

# Variables sin las que el backend no puede funcionar.
# GOOGLE_CLIENT_ID es opcional: sin ella solo se desactiva /auth/google (503).
REQUIRED_ENV_VARS = (
    "OPENAI_API_KEY",
    "SECRET_KEY",
    "ALGORITHM",
    "ACCESS_TOKEN_EXPIRE_MINUTES",
)

# Los JWT de CRMVoice se firman con SECRET_KEY (clave simétrica): solo HMAC.
SUPPORTED_ALGORITHMS = ("HS256", "HS384", "HS512")

MIN_SECRET_KEY_LENGTH = 32

GENERATE_SECRET_KEY_HINT = (
    'Genera una con: python -c "import secrets; print(secrets.token_urlsafe(64))" '
    "(en macOS/Linux, python3) y pégala en backend/.env."
)

# Valores de ejemplo o triviales que nunca deben usarse como clave real
_PLACEHOLDER_SECRET_KEYS = {
    "changeme", "change-me", "change_me", "secret", "secret-key", "secret_key",
    "your-secret-key", "your_secret_key", "cambia-esto-por-una-clave-aleatoria-larga",
}


def _is_placeholder(value: str) -> bool:
    """Detecta valores de plantilla tipo 'sk-...', '<tu-clave>' o 'xxxx'."""
    v = value.strip()
    return (
        "..." in v
        or "…" in v
        or (v.startswith("<") and v.endswith(">"))
        or set(v.lower()) <= {"x", "-", "_"}
    )


def check_required_env():
    """
    Falla al arrancar con un mensaje claro si la configuración obligatoria
    falta o sigue siendo la de ejemplo. Nunca muestra los valores.
    """
    problems = []

    missing = [name for name in REQUIRED_ENV_VARS if not os.getenv(name, "").strip()]
    if missing:
        problems.append("Faltan variables obligatorias: " + ", ".join(missing) + ".")

    openai_key = os.getenv("OPENAI_API_KEY", "").strip()
    if openai_key and _is_placeholder(openai_key):
        problems.append("OPENAI_API_KEY sigue siendo un valor de ejemplo: pon tu clave de la API de OpenAI.")

    secret_key = os.getenv("SECRET_KEY", "").strip()
    if secret_key:
        if secret_key.lower() in _PLACEHOLDER_SECRET_KEYS or _is_placeholder(secret_key):
            problems.append("SECRET_KEY sigue siendo un valor de ejemplo. " + GENERATE_SECRET_KEY_HINT)
        elif len(secret_key) < MIN_SECRET_KEY_LENGTH:
            problems.append(
                f"SECRET_KEY es demasiado corta (mínimo {MIN_SECRET_KEY_LENGTH} caracteres). "
                + GENERATE_SECRET_KEY_HINT
            )

    algorithm = os.getenv("ALGORITHM", "").strip()
    if algorithm and algorithm not in SUPPORTED_ALGORITHMS:
        problems.append(
            "ALGORITHM no soportado: usa " + ", ".join(SUPPORTED_ALGORITHMS) + " (recomendado HS256)."
        )

    minutes_raw = os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "").strip()
    if minutes_raw:
        try:
            minutes = int(minutes_raw)
        except ValueError:
            minutes = 0
        if minutes <= 0:
            problems.append("ACCESS_TOKEN_EXPIRE_MINUTES debe ser un número entero positivo (por ejemplo 60).")

    if problems:
        raise RuntimeError(
            "Configuración del backend no válida:\n  - "
            + "\n  - ".join(problems)
            + "\nRevisa backend/.env (plantilla: backend/.env.example)."
        )
