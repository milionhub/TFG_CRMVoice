"""
Confirmación de un borrador (H.2): el ÚNICO camino por el que una acción
interpretada llega a escribir datos de negocio.

POST /actions/{id}/confirm {revision}: la petición NO trae datos de negocio.
Se escribe exactamente lo guardado en el borrador, revalidado contra la BD
actual, en UNA transacción (BEGIN IMMEDIATE):

1. carga por public_id + comercial (de otro = inexistente: 404);
2. estado: ejecutado -> devuelve el resultado guardado (idempotente, doble
   clic); cancelado -> 409; caducado -> 410; otra revisión -> 409
   stale_revision;
3. revalida (issues_for: existencia, contacto ∈ cliente, duplicados, reglas):
   si ahora hay algo bloqueante, guarda los issues nuevos (revisión + 1),
   sigue abierto y responde 422 con el borrador actualizado;
4. escribe con el servicio de escritura usando ESTA conexión;
5. marca el borrador como ejecutado con UPDATE ... WHERE status = 'open' AND
   revision = ? (rowcount 1); si no, deshace todo;
6. commit. Después, fuera de la transacción, el embedding (best-effort).

SQLite serializa las transacciones de escritura: una segunda confirmación
simultánea espera, encuentra el borrador ejecutado y devuelve el mismo
resultado sin escribir nada más.
"""
import json
import sqlite3
from datetime import datetime

import db
from core.formats import iso_now
from schemas.issues import Issue, has_blocking
from services import activities as activity_reads
from services.actions import drafts, resolver
from services.writes import (Conflict, Duplicate, Gone, ValidationFailed, current_time, integrity_issue)
from services.writes import activities as activity_writes
from services.writes import clients as client_writes
from services.writes import contacts as contact_writes
from services.writes import sales as sale_writes


def _execute(action_type: str, data, provenance: dict, salesperson_id: int, conn: sqlite3.Connection,
             now: datetime, source_text: str) -> dict:
    if action_type == "create_activity":
        created = activity_writes.create_activity(data, salesperson_id, conn=conn, now=now,
                                                  provenance={**provenance, "transcription": source_text})
        return {"entity": "activity", "ids": [created["id"]], "data": created}
    if action_type == "create_client":
        created = client_writes.create_client(data, salesperson_id, conn=conn, now=now)
        return {"entity": "client", "ids": [created["id"]], "data": created}
    if action_type == "create_contact":
        created = contact_writes.create_contact(data, salesperson_id, conn=conn, now=now)
        return {"entity": "contact", "ids": [created["id"]], "data": created}
    created = sale_writes.create_sales(data, salesperson_id, conn=conn, now=now)
    return {"entity": "sale", "ids": [s["id"] for s in created], "data": created}


def _refresh_blocked(public_id: str, salesperson_id: int, revision: int, issues: list[Issue],
                     now: datetime) -> dict:
    """Guarda los issues que impiden confirmar (revisión + 1) en una transacción nueva."""
    conn = db.get_connection()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = drafts.load(conn, public_id, salesperson_id)
        if row["status"] != "open" or row["revision"] != revision:
            conn.execute("ROLLBACK")
            return drafts.view(row, now)
        fields = resolver.load_fields(row["action_type"], row["payload"])
        draft = drafts.save_revision(conn, row, fields, issues, now)
        conn.execute("COMMIT")
        return draft
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def _blocked(issues: list[Issue], draft: dict) -> ValidationFailed:
    blocking = [i for i in issues if i.blocking]
    message = "No se puede confirmar: " + blocking[0].message if blocking else "No se puede confirmar."
    return ValidationFailed(issues, message, extra={"draft": draft})


def confirm(public_id: str, salesperson_id: int, revision: int, *, now: datetime | None = None) -> dict:
    """{"result", "draft"}. Idempotente: un borrador ya ejecutado devuelve su resultado sin escribir."""
    now = now or current_time()
    conn = db.get_connection()
    blocked_issues = None
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = drafts.load(conn, public_id, salesperson_id)
        if row["status"] == "executed":
            conn.execute("ROLLBACK")
            return {"result": json.loads(row["result"]), "draft": drafts.view(row, now)}
        if row["status"] == "cancelled":
            raise Conflict("draft_cancelled", "Este borrador está cancelado: no se puede confirmar.",
                           extra={"draft": drafts.view(row, now)})
        if drafts.is_expired(row, now):
            raise Gone("draft_expired", drafts.DRAFT_EXPIRED)
        if revision != row["revision"]:
            raise Conflict("stale_revision", "El borrador ha cambiado: revisa la versión actual antes de confirmar.",
                           extra={"draft": drafts.view(row, now), "current_revision": row["revision"]})

        action_type = row["action_type"]
        fields = resolver.load_fields(action_type, row["payload"])
        issues = resolver.issues_for(action_type, fields, salesperson_id, now, conn)
        if has_blocking(issues):
            draft = drafts.save_revision(conn, row, fields, issues, now)
            conn.execute("COMMIT")
            raise _blocked(issues, draft)

        data, provenance = resolver.write_input(action_type, fields, now)
        try:
            result = _execute(action_type, data, provenance, salesperson_id, conn, now, row["source_text"])
        except (Duplicate, ValidationFailed) as error:
            blocked_issues = error.issues            # carrera: algo cambió entre la revalidación y la escritura
            raise
        except sqlite3.IntegrityError as error:
            blocked_issues = [integrity_issue(error)]
            raise

        marked = conn.execute("""
            UPDATE action_drafts SET status = 'executed', result = ?, updated_at = ?
            WHERE id = ? AND status = 'open' AND revision = ?
        """, (json.dumps(result, ensure_ascii=False), iso_now(now), row["id"], revision)).rowcount
        if marked != 1:
            raise Conflict("stale_revision", "El borrador ha cambiado mientras se confirmaba.")
        conn.execute("COMMIT")
        executed = conn.execute("SELECT * FROM action_drafts WHERE id = ?", (row["id"],)).fetchone()
    except BaseException:
        if conn.in_transaction:
            conn.execute("ROLLBACK")      # nada a medias: ni negocio ni borrador
        if blocked_issues is None:
            raise
    finally:
        conn.close()

    if blocked_issues is not None:
        draft = _refresh_blocked(public_id, salesperson_id, revision, blocked_issues, now)
        raise _blocked(blocked_issues, draft)

    if result["entity"] == "activity":
        activity_reads.ensure_embedding(result["ids"][0])   # después del commit; si falla, no deshace nada
    return {"result": result, "draft": drafts.view(executed, now)}
