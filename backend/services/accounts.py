"""
Cuentas de comerciales (tabla salespeople).

Sin dependencias de FastAPI: los routers traducen los resultados y las
excepciones de este módulo a respuestas HTTP.

El email identifica la cuenta sin distinguir mayúsculas (B16): las cuentas
nuevas lo guardan normalizado y las búsquedas comparan en minúsculas, así
que también se encuentran las cuentas antiguas guardadas con mayúsculas.
"""
import sqlite3
from datetime import datetime, timezone

from db import get_connection


class AccountConflict(Exception):
    """El email ya pertenece a otra cuenta: no se vincula automáticamente (409)."""


class EmailAlreadyRegistered(Exception):
    """Otra petición registró el mismo email entre la comprobación y el INSERT."""


def normalize_email(email: str) -> str:
    return email.strip().lower()


def find_by_email(email: str):
    """Fila (id, nombre, email, password_hash) o None."""
    conn = get_connection()

    try:
        return conn.execute("""
            SELECT id, nombre, email, password_hash
            FROM salespeople
            WHERE lower(email) = ?
            ORDER BY id
        """, (normalize_email(email),)).fetchone()
    finally:
        conn.close()


def email_exists(email: str) -> bool:
    return find_by_email(email) is not None


def user_exists(user_id: int) -> bool:
    conn = get_connection()

    try:
        return conn.execute("SELECT 1 FROM salespeople WHERE id = ?", (user_id,)).fetchone() is not None
    finally:
        conn.close()


def create_password_account(nombre: str, email: str, password_hash: str) -> int:
    """Crea una cuenta con contraseña (email normalizado) y devuelve su id."""
    conn = get_connection()

    try:
        cursor = conn.execute("""
            INSERT INTO salespeople (nombre, email, password_hash, created_at)
            VALUES (?, ?, ?, ?)
        """, (nombre, normalize_email(email), password_hash,
              datetime.now(timezone.utc).replace(tzinfo=None)))
        conn.commit()
        return cursor.lastrowid
    except sqlite3.IntegrityError as error:
        if "salespeople.email" in str(error):
            raise EmailAlreadyRegistered() from error
        raise
    finally:
        conn.close()


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


def _email_conflict(existing) -> AccountConflict:
    if existing["google_id"]:
        return AccountConflict("El email ya está asociado a otra cuenta de Google")

    return AccountConflict(
        "Este email ya tiene una cuenta en CRMVoice. Inicia sesión con tu contraseña."
    )


def get_or_create_google_account(google_id: str, email: str, name: str):
    """
    Cuenta asociada al google_id (sub) del ID token ya verificado; si no
    existe, se crea. Si el email pertenece a otra cuenta (con contraseña o de
    otra cuenta de Google) lanza AccountConflict: nunca se vincula sola.
    """
    email = normalize_email(email)
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
                "SELECT * FROM salespeople WHERE lower(email) = ? ORDER BY id",
                (email,)
            )

            existing = cursor.fetchone()

            if existing:
                raise _email_conflict(existing)

            # crear usuario si no existe
            try:
                cursor.execute(
                    """
                    INSERT INTO salespeople (nombre, email, google_id)
                    VALUES (?, ?, ?)
                    """,
                    (name, email, google_id)
                )
            except sqlite3.IntegrityError:
                # B15: otra petición creó la cuenta entre el SELECT y el INSERT.
                # Se vuelve a consultar; solo se da por buena la cuenta de ESTE
                # google_id. Cualquier otro caso es conflicto o error real.
                conn.rollback()

                cursor.execute("SELECT * FROM salespeople WHERE google_id = ?", (google_id,))
                user = cursor.fetchone()

                if user:
                    return user

                cursor.execute(
                    "SELECT * FROM salespeople WHERE lower(email) = ? ORDER BY id",
                    (email,)
                )
                existing = cursor.fetchone()

                if existing:
                    raise _email_conflict(existing)

                raise

            conn.commit()

            cursor.execute(
                "SELECT * FROM salespeople WHERE google_id = ?",
                (google_id,)
            )

            user = cursor.fetchone()

    finally:
        conn.close()

    return user
