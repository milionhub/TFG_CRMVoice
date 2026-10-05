"""
Actividades V2 (H.2): alta, edición, cambio de estado y borrado, SIEMPRE del
comercial autenticado (WHERE salesperson_id = ?; la de otro = no existe).

Reglas (activity_issues, que también usa el Action Engine):
- cliente y tipo obligatorios y existentes; contacto opcional, existente y
  DEL cliente; productos existentes; fecha "YYYY-MM-DDTHH:MM:SS" (hora local);
- estado explícito: "completed" con fecha futura no es válido; "pending" en
  el pasado sí (vencida); "cancelled" con cualquier fecha;
- duplicado exacto (bloquea, 409): mismo comercial, cliente, contacto (NULL
  incluido), tipo y fecha al minuto, contra actividades no canceladas. Es
  determinista: los embeddings ya no intervienen (B2).

El embedding de búsqueda semántica NO se genera aquí: después del commit,
services.activities.ensure_embedding (si falla, la actividad ya está guardada).
"""
import sqlite3
from datetime import datetime

from core.formats import iso_now
from schemas.crm import ActivityIn, ActivityStatus
from schemas.issues import Candidate, Issue, issue
from services.writes import (NotFound, ValidationFailed, contact_issue, current_time, exists, raise_if_blocking,
                             transaction)


def _is_future(datetime_iso: str, now: datetime) -> bool:
    return datetime_iso > iso_now(now)


def _status_issue(status: str, datetime_iso: str, now: datetime) -> Issue | None:
    if status == "completed" and _is_future(datetime_iso, now):
        return issue("invalid", "status", "Una actividad futura no puede estar completada: márcala como pendiente.")
    return None


def duplicate_of(conn: sqlite3.Connection, data: ActivityIn, salesperson_id: int, *,
                 exclude_id: int | None = None) -> int | None:
    """Id de una actividad idéntica no cancelada del comercial (al minuto), o None."""
    if data.status == "cancelled":
        return None
    row = conn.execute("""
        SELECT id FROM activities
        WHERE salesperson_id = ? AND client_id = ? AND contact_id IS ? AND activity_type_id = ?
          AND substr(datetime_iso, 1, 16) = ? AND status != 'cancelled' AND id IS NOT ?
        ORDER BY id LIMIT 1
    """, (salesperson_id, data.client_id, data.contact_id, data.activity_type_id, data.datetime[:16],
          exclude_id)).fetchone()
    return row["id"] if row else None


def activity_issues(conn: sqlite3.Connection, data: ActivityIn, salesperson_id: int, now: datetime, *,
                    exclude_id: int | None = None) -> list[Issue]:
    issues = []
    if not exists(conn, "clients", data.client_id):
        issues.append(issue("not_found", "client", "El cliente no existe."))
    elif (problem := contact_issue(conn, data.client_id, data.contact_id)) is not None:
        issues.append(problem)
    if not exists(conn, "activity_types", data.activity_type_id):
        issues.append(issue("not_found", "activity_type", "El tipo de actividad no existe."))
    for index, product_id in enumerate(data.product_ids):
        if not exists(conn, "products", product_id):
            issues.append(issue("not_found", f"products[{index}]", "El producto no existe."))
    if (problem := _status_issue(data.status, data.datetime, now)) is not None:
        issues.append(problem)
    if not issues and (existing := duplicate_of(conn, data, salesperson_id, exclude_id=exclude_id)):
        issues.append(issue("duplicate", "activity",
                            "Ya tienes esa misma actividad (mismo cliente, contacto, tipo y hora).",
                            existing_id=existing, candidates=[Candidate(id=existing, label=data.datetime[:16])]))
    return issues


def activity_out(conn: sqlite3.Connection, activity_id: int) -> dict:
    row = conn.execute("""
        SELECT a.id, a.client_id, c.razon_social AS client_name, a.contact_id, ct.nombre AS contact_name,
               a.activity_type_id, t.accion AS activity_type, a.datetime_iso, a.status, a.comentario
        FROM activities a
        LEFT JOIN clients c ON c.id = a.client_id
        LEFT JOIN contacts ct ON ct.id = a.contact_id
        LEFT JOIN activity_types t ON t.id = a.activity_type_id
        WHERE a.id = ?
    """, (activity_id,)).fetchone()
    products = conn.execute("""
        SELECT p.id, p.nombre FROM activity_products ap JOIN products p ON p.id = ap.product_id
        WHERE ap.activity_id = ? ORDER BY ap.id
    """, (activity_id,)).fetchall()
    return {"id": row["id"], "client_id": row["client_id"], "client_name": row["client_name"],
            "contact_id": row["contact_id"], "contact_name": row["contact_name"],
            "activity_type_id": row["activity_type_id"], "activity_type": row["activity_type"],
            "datetime": row["datetime_iso"], "status": row["status"], "comment": row["comentario"],
            "products": [{"id": p["id"], "name": p["nombre"]} for p in products]}


def _insert_products(conn, activity_id: int, product_ids: list[int], provenance: dict) -> None:
    raw = provenance.get("product_raw") or {}
    confidence = provenance.get("product_confidence") or {}
    for product_id in product_ids:
        conn.execute("""
            INSERT INTO activity_products (activity_id, product_id, product_raw, confidence_score)
            VALUES (?, ?, ?, ?)
        """, (activity_id, product_id, raw.get(product_id), confidence.get(product_id)))


def create_activity(data: ActivityIn, salesperson_id: int, *, conn: sqlite3.Connection | None = None,
                    now: datetime | None = None, provenance: dict | None = None) -> dict:
    """
    provenance (opcional, interno): transcripción y menciones originales
    (voz/borrador) que se guardan para auditoría; nunca deciden nada.
    """
    now = now or current_time()
    provenance = provenance or {}
    with transaction(conn) as c:
        raise_if_blocking(activity_issues(c, data, salesperson_id, now))
        activity_id = c.execute("""
            INSERT INTO activities (datetime_iso, client_id, contact_id, activity_type_id, salesperson_id,
                                    comentario, transcripcion, cliente_raw, contacto_raw, accion_raw,
                                    resolution_status, resolution_confidence, status, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (data.datetime, data.client_id, data.contact_id, data.activity_type_id, salesperson_id,
              data.comment, provenance.get("transcription"), provenance.get("cliente_raw"),
              provenance.get("contacto_raw"), provenance.get("accion_raw"), provenance.get("resolution_status"),
              provenance.get("resolution_confidence"), data.status, iso_now(now))).lastrowid
        _insert_products(c, activity_id, data.product_ids, provenance)
        return activity_out(c, activity_id)


def owned_activity(conn: sqlite3.Connection, activity_id: int, salesperson_id: int) -> sqlite3.Row:
    row = conn.execute("SELECT id, status, comentario, datetime_iso FROM activities WHERE id = ? AND salesperson_id = ?",
                       (activity_id, salesperson_id)).fetchone()
    if row is None:
        raise NotFound("Actividad no encontrada")
    return row


def update_activity(activity_id: int, data: ActivityIn, salesperson_id: int, *,
                    conn: sqlite3.Connection | None = None, now: datetime | None = None,
                    provenance: dict | None = None) -> dict:
    """Sustitución completa (PUT). Si cambia el comentario, el embedding queda obsoleto y se borra."""
    now = now or current_time()
    with transaction(conn) as c:
        current = owned_activity(c, activity_id, salesperson_id)  # la propiedad antes que nada
        raise_if_blocking(activity_issues(c, data, salesperson_id, now, exclude_id=activity_id))
        c.execute("""
            UPDATE activities SET datetime_iso = ?, client_id = ?, contact_id = ?, activity_type_id = ?,
                                  comentario = ?, status = ?, updated_at = ?
            WHERE id = ? AND salesperson_id = ?
        """, (data.datetime, data.client_id, data.contact_id, data.activity_type_id, data.comment, data.status,
              iso_now(now), activity_id, salesperson_id))
        c.execute("DELETE FROM activity_products WHERE activity_id = ?", (activity_id,))
        _insert_products(c, activity_id, data.product_ids, provenance or {})
        if data.comment != current["comentario"]:
            c.execute("DELETE FROM activity_embeddings WHERE activity_id = ?", (activity_id,))
        return activity_out(c, activity_id)


def set_activity_status(activity_id: int, status: ActivityStatus, salesperson_id: int, *,
                        conn: sqlite3.Connection | None = None, now: datetime | None = None) -> dict:
    """Idempotente: poner el estado que ya tiene no cambia nada (ni updated_at)."""
    now = now or current_time()
    with transaction(conn) as c:
        current = owned_activity(c, activity_id, salesperson_id)
        if current["status"] == status:
            return activity_out(c, activity_id)
        problem = _status_issue(status, current["datetime_iso"] or "", now)
        if problem is not None:
            raise ValidationFailed([problem], problem.message)
        if current["status"] == "cancelled":
            # Reactivar una cancelada no puede crear un duplicado de otra activa
            full = activity_out(c, activity_id)
            candidate = ActivityIn.model_construct(
                client_id=full["client_id"], contact_id=full["contact_id"],
                activity_type_id=full["activity_type_id"], datetime=full["datetime"] or "", status=status)
            if (existing := duplicate_of(c, candidate, salesperson_id, exclude_id=activity_id)) is not None:
                raise_if_blocking([issue("duplicate", "activity", "Ya tienes esa misma actividad activa.",
                                         existing_id=existing)])
        c.execute("UPDATE activities SET status = ?, updated_at = ? WHERE id = ? AND salesperson_id = ?",
                  (status, iso_now(now), activity_id, salesperson_id))
        return activity_out(c, activity_id)


def delete_activity(activity_id: int, salesperson_id: int, *, conn: sqlite3.Connection | None = None) -> None:
    """Borra la actividad del comercial con sus productos y su embedding."""
    with transaction(conn) as c:
        owned_activity(c, activity_id, salesperson_id)
        c.execute("DELETE FROM activity_products WHERE activity_id = ?", (activity_id,))
        c.execute("DELETE FROM activity_embeddings WHERE activity_id = ?", (activity_id,))
        deleted = c.execute("DELETE FROM activities WHERE id = ? AND salesperson_id = ?",
                            (activity_id, salesperson_id)).rowcount
        if deleted != 1:
            raise NotFound("Actividad no encontrada")
