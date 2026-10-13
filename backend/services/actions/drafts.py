"""
Borradores del Action Engine (H.2): persistencia y ciclo de vida.

- Pertenecen a un comercial: TODA búsqueda es public_id + salesperson_id; el
  de otro y el inexistente dan el mismo 404 (NotFound).
- public_id aleatorio (secrets.token_urlsafe), no enumerable.
- Estado persistido: open -> executed | cancelled. "confirmable" y
  "expired" se derivan (abierto, sin caducar y sin issues bloqueantes).
- Caduca 30 min después de crearse o de su última edición; los caducados se
  purgan perezosamente (sin planificador) al crear otro.
- Cada edición correcta sube la revisión; confirmar exige la revisión vista.
- La interpretación en bruto del modelo se guarda (auditoría) pero NUNCA
  sale en la vista pública (DraftView).
"""
import json
import secrets
import sqlite3
from datetime import datetime

from pydantic import BaseModel

from core.formats import iso_now
from db import connection
from schemas.actions import DraftView
from schemas.issues import Issue, has_blocking
from services.actions import resolver
from services.actions.types import DRAFT_TTL, PURGE_AFTER
from services.writes import Conflict, Gone, NotFound, current_time, transaction

DRAFT_NOT_FOUND = "Borrador no encontrado"
DRAFT_EXPIRED = "El borrador ha caducado: vuelve a dictar o escribir la acción."


def load(conn: sqlite3.Connection, public_id: str, salesperson_id: int) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM action_drafts WHERE public_id = ? AND salesperson_id = ?",
                       (public_id, salesperson_id)).fetchone()
    if row is None:
        raise NotFound(DRAFT_NOT_FOUND)
    return row


def is_expired(row, now: datetime) -> bool:
    return row["status"] == "open" and row["expires_at"] < iso_now(now)


def view(row, now: datetime) -> dict:
    issues = [Issue.model_validate(i) for i in json.loads(row["issues"])]
    expired = is_expired(row, now)
    return DraftView(
        id=row["public_id"], action_type=row["action_type"], status=row["status"], revision=row["revision"],
        source=row["source"], source_text=row["source_text"], fields=json.loads(row["payload"]),
        issues=issues, confirmable=row["status"] == "open" and not expired and not has_blocking(issues),
        expired=expired, expires_at=row["expires_at"],
        result=json.loads(row["result"]) if row["result"] else None,
        created_at=row["created_at"], updated_at=row["updated_at"],
    ).model_dump()


def _dump_issues(issues: list[Issue]) -> str:
    return json.dumps([i.model_dump() for i in issues], ensure_ascii=False)


def create(salesperson_id: int, action_type: str, source: str, source_text: str, interpretation: BaseModel,
           fields: BaseModel, now: datetime) -> dict:
    """Guarda el borrador con sus issues calculados ahora (sin escribir nada de negocio)."""
    stamp = iso_now(now)
    with transaction() as conn:
        conn.execute("DELETE FROM action_drafts WHERE salesperson_id = ? AND expires_at < ?",
                     (salesperson_id, iso_now(now - PURGE_AFTER)))
        issues = resolver.issues_for(action_type, fields, salesperson_id, now, conn)
        conn.execute("""
            INSERT INTO action_drafts (public_id, salesperson_id, action_type, status, revision, source, source_text,
                                       interpretation, payload, issues, created_at, updated_at, expires_at)
            VALUES (?, ?, ?, 'open', 1, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (secrets.token_urlsafe(16), salesperson_id, action_type, source, source_text,
              interpretation.model_dump_json(), fields.model_dump_json(), _dump_issues(issues),
              stamp, stamp, iso_now(now + DRAFT_TTL)))
        row = conn.execute("SELECT * FROM action_drafts WHERE id = last_insert_rowid()").fetchone()
        return view(row, now)


def get(public_id: str, salesperson_id: int, *, now: datetime | None = None) -> dict:
    now = now or current_time()
    with connection() as conn:            # solo lectura: sin el bloqueo de escritura
        row = load(conn, public_id, salesperson_id)
    if is_expired(row, now):
        raise Gone("draft_expired", DRAFT_EXPIRED)
    return view(row, now)


def _check_editable(row, revision: int, now: datetime) -> None:
    if row["status"] != "open":
        raise Conflict(f"draft_{row['status']}", "Este borrador ya está cerrado: no se puede cambiar.",
                       extra={"draft": view(row, now)})
    if is_expired(row, now):
        raise Gone("draft_expired", DRAFT_EXPIRED)
    if revision != row["revision"]:
        raise Conflict("stale_revision", "El borrador ha cambiado: revisa la versión actual.",
                       extra={"draft": view(row, now), "current_revision": row["revision"]})


def save_revision(conn: sqlite3.Connection, row, fields: BaseModel, issues: list[Issue], now: datetime) -> dict:
    """Nueva revisión (solo si sigue abierta y en la revisión esperada) y TTL renovado."""
    updated = conn.execute("""
        UPDATE action_drafts SET payload = ?, issues = ?, revision = revision + 1, updated_at = ?, expires_at = ?
        WHERE id = ? AND status = 'open' AND revision = ?
    """, (fields.model_dump_json(), _dump_issues(issues), iso_now(now), iso_now(now + DRAFT_TTL),
          row["id"], row["revision"])).rowcount
    if updated != 1:
        raise Conflict("stale_revision", "El borrador ha cambiado: revisa la versión actual.")
    return view(conn.execute("SELECT * FROM action_drafts WHERE id = ?", (row["id"],)).fetchone(), now)


def edit(public_id: str, salesperson_id: int, revision: int, edits: dict, *, now: datetime | None = None) -> dict:
    now = now or current_time()
    with transaction() as conn:
        row = load(conn, public_id, salesperson_id)
        _check_editable(row, revision, now)
    # Resolución (solo lecturas locales, sin red) fuera de la transacción de escritura
    fields = resolver.apply_edits(row["action_type"], resolver.load_fields(row["action_type"], row["payload"]),
                                  edits, salesperson_id, now)
    with transaction() as conn:
        current = load(conn, public_id, salesperson_id)
        _check_editable(current, revision, now)      # nadie lo ha cambiado mientras tanto
        issues = resolver.issues_for(current["action_type"], fields, salesperson_id, now, conn)
        return save_revision(conn, current, fields, issues, now)


def cancel(public_id: str, salesperson_id: int, *, now: datetime | None = None) -> dict:
    """Idempotente: cancelar uno ya cancelado devuelve el mismo borrador. Ejecutado -> 409; caducado -> 410."""
    now = now or current_time()
    with transaction() as conn:
        row = load(conn, public_id, salesperson_id)
        if row["status"] == "executed":
            raise Conflict("draft_executed", "Este borrador ya se confirmó: no se puede cancelar.",
                           extra={"draft": view(row, now)})
        if row["status"] == "open":
            if is_expired(row, now):
                raise Gone("draft_expired", DRAFT_EXPIRED)
            conn.execute("UPDATE action_drafts SET status = 'cancelled', updated_at = ? WHERE id = ? AND status = 'open'",
                         (iso_now(now), row["id"]))
        return view(conn.execute("SELECT * FROM action_drafts WHERE id = ?", (row["id"],)).fetchone(), now)


__all__ = ["load", "view", "create", "get", "edit", "cancel", "save_revision", "is_expired"]
