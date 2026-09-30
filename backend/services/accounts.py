"""
Cuentas de comerciales (tabla salespeople).

Sin dependencias de FastAPI: los routers traducen los resultados y las
excepciones de este módulo a respuestas HTTP.
"""
from datetime import datetime

from db import get_connection


class AccountConflict(Exception):
    """El email ya pertenece a otra cuenta: no se vincula automáticamente (409)."""


def find_by_email(email: str):
    """Fila (id, nombre, email, password_hash) o None."""
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, nombre, email, password_hash
        FROM salespeople
        WHERE email = ?
    """, (email,))

    user = cursor.fetchone()
    conn.close()
    return user


def email_exists(email: str) -> bool:
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id FROM salespeople WHERE email = ?
    """, (email,))

    existing_user = cursor.fetchone()
    conn.close()
    return existing_user is not None


def create_password_account(nombre: str, email: str, password_hash: str) -> int:
    """Crea una cuenta con contraseña y devuelve su id."""
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        INSERT INTO salespeople (nombre, email, password_hash, created_at)
        VALUES (?, ?, ?, ?)
    """, (nombre, email, password_hash, datetime.utcnow()))

    conn.commit()
    user_id = cursor.lastrowid
    conn.close()
    return user_id


def get_profile(user_id: int):
    """Fila (id, nombre, email, created_at) o None."""
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, nombre, email, created_at
        FROM salespeople
        WHERE id = ?
    """, (user_id,))

    user = cursor.fetchone()
    conn.close()
    return user


def get_or_create_google_account(google_id: str, email: str, name: str):
    """
    Cuenta asociada al google_id (sub) del ID token ya verificado; si no
    existe, se crea. Si el email pertenece a otra cuenta (con contraseña o de
    otra cuenta de Google) lanza AccountConflict: nunca se vincula sola.
    """
    conn = get_connection()
    cursor = conn.cursor()

    try:

        cursor.execute(
            "SELECT * FROM salespeople WHERE google_id = ?",
            (google_id,)
        )

        user = cursor.fetchone()

        if not user:

            # ¿Ya existe una cuenta con ese email? → NO se enlaza automáticamente:
            # la cuenta tradicional debe entrar con su contraseña
            cursor.execute(
                "SELECT * FROM salespeople WHERE email = ?",
                (email,)
            )

            existing = cursor.fetchone()

            if existing:

                if existing["google_id"]:
                    raise AccountConflict("El email ya está asociado a otra cuenta de Google")

                raise AccountConflict(
                    "Este email ya tiene una cuenta en CRMVoice. Inicia sesión con tu contraseña."
                )

            # crear usuario si no existe
            cursor.execute(
                """
                INSERT INTO salespeople (nombre, email, google_id)
                VALUES (?, ?, ?)
                """,
                (name, email, google_id)
            )

            conn.commit()

            cursor.execute(
                "SELECT * FROM salespeople WHERE google_id = ?",
                (google_id,)
            )

            user = cursor.fetchone()

    finally:
        conn.close()

    return user
