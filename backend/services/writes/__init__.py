"""
Servicios de escritura del CRM (H.2): la ÚNICA puerta para crear o cambiar
clientes, contactos, actividades y ventas. Los usan igual los endpoints REST
(formularios) y la confirmación de un borrador del Action Engine.

Contrato común:
- entradas tipadas (schemas.crm) y el comercial siempre del token;
- toda la validación de negocio vive aquí (las rutas solo traducen errores);
- errores de dominio: NotFound (404), ValidationFailed (422, con issues),
  Duplicate (409, con issues) y Conflict (409);
- transacción: sin `conn`, el servicio abre la suya (BEGIN IMMEDIATE, commit
  o rollback); con `conn`, la transacción es de quien llama (el Action Engine
  confirma el borrador y escribe en la misma);
- nada de red dentro de una transacción (el embedding de una actividad se
  genera después del commit, y si falla no deshace nada).
"""
import sqlite3
from contextlib import contextmanager
from datetime import datetime

from pydantic import ValidationError

import db
from schemas.issues import Issue, has_blocking, issue, issues_from_pydantic


class WriteError(Exception):
    """
    Error de dominio; `message` es apto para el usuario. `extra`: datos
    adicionales seguros para la respuesta (p. ej. el borrador actualizado).
    """

    def __init__(self, message: str, *, extra: dict | None = None):
        super().__init__(message)
        self.message = message
        self.extra = extra or {}


class NotFound(WriteError):
    """No existe o no es del comercial (misma respuesta en los dos casos)."""


class ValidationFailed(WriteError):
    def __init__(self, issues: list[Issue], message: str = "Datos no válidos", *, extra: dict | None = None):
        super().__init__(message, extra=extra)
        self.issues = issues


class Duplicate(WriteError):
    def __init__(self, code: str, message: str, existing_id: int | None, issues: list[Issue]):
        super().__init__(message)
        self.code = code
        self.existing_id = existing_id
        self.issues = issues


class Conflict(WriteError):
    def __init__(self, code: str, message: str, *, extra: dict | None = None):
        super().__init__(message, extra=extra)
        self.code = code


class Gone(WriteError):
    """Existía pero ya no se puede usar (borrador caducado): 410."""

    def __init__(self, code: str, message: str, *, extra: dict | None = None):
        super().__init__(message, extra=extra)
        self.code = code


class ServiceUnavailable(WriteError):
    """Un servicio externo (IA, transcripción) no responde: 503 con mensaje seguro."""

    def __init__(self, code: str, message: str, *, extra: dict | None = None):
        super().__init__(message, extra=extra)
        self.code = code


def current_time() -> datetime:
    """Hora local del servidor, sin microsegundos (la misma referencia que el chat)."""
    return datetime.now().replace(microsecond=0)


@contextmanager
def transaction(conn: sqlite3.Connection | None = None):
    """
    Sin conn: conexión propia con BEGIN IMMEDIATE (las comprobaciones y la
    escritura van en la misma transacción, sin carreras), commit/rollback y
    cierre. Con conn: se usa tal cual; commit y rollback son de quien llama.
    """
    if conn is not None:
        yield conn
        return
    own = db.get_connection()
    try:
        own.isolation_level = None
        own.execute("BEGIN IMMEDIATE")
        try:
            yield own
            own.execute("COMMIT")
        except BaseException:
            own.execute("ROLLBACK")
            raise
    finally:
        own.close()


def raise_if_blocking(issues: list[Issue], *, duplicate_message: str | None = None) -> None:
    """Duplicado como único problema bloqueante -> Duplicate (409); cualquier otro -> ValidationFailed (422)."""
    blocking = [i for i in issues if i.blocking]
    if not blocking:
        return
    if all(i.code == "duplicate" for i in blocking):
        first = blocking[0]
        raise Duplicate(f"duplicate_{first.field}", duplicate_message or first.message, first.existing_id, blocking)
    raise ValidationFailed(blocking, blocking[0].message)


def validation_issues(error: ValidationError, *, prefix: str = "") -> list[Issue]:
    """Errores de Pydantic -> issues "invalid"/"missing" en español ("lines[0].amount")."""
    return issues_from_pydantic(error.errors(), prefix=prefix)


def validation_failed(error: ValidationError, *, prefix: str = "") -> ValidationFailed:
    issues = validation_issues(error, prefix=prefix)
    first = issues[0]
    return ValidationFailed(issues, f"{first.message} ({first.field})")


def integrity_issue(error: sqlite3.IntegrityError) -> Issue:
    """Una violación que se ha escapado a la validación (defensa en profundidad)."""
    text = str(error)
    if "contact_client_mismatch" in text:
        return issue("conflict", "contact", "El contacto no pertenece a ese cliente.")
    return issue("invalid", "body", "Los datos hacen referencia a registros que no existen.")


def exists(conn: sqlite3.Connection, table: str, row_id: int | None) -> bool:
    if row_id is None:
        return False
    return conn.execute(f"SELECT 1 FROM {table} WHERE id = ?", (row_id,)).fetchone() is not None


def contact_issue(conn: sqlite3.Connection, client_id: int | None, contact_id: int | None,
                  *, field: str = "contact") -> Issue | None:
    """Regla central: el contacto (si hay) existe y es del cliente indicado."""
    if contact_id is None:
        return None
    row = conn.execute("SELECT client_id, nombre FROM contacts WHERE id = ?", (contact_id,)).fetchone()
    if row is None:
        return issue("not_found", field, "El contacto no existe.")
    if client_id is not None and row["client_id"] != client_id:
        return issue("conflict", field, f"{row['nombre']} no es un contacto de ese cliente.")
    return None


__all__ = ["WriteError", "NotFound", "ValidationFailed", "Duplicate", "Conflict", "Gone",
           "ServiceUnavailable", "current_time", "transaction",
           "raise_if_blocking", "validation_issues", "validation_failed", "integrity_issue", "exists", "contact_issue", "has_blocking"]
