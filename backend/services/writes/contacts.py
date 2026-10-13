"""
Contactos (H.2): alta y edición. Compartidos como sus clientes
(created_by_salesperson_id es solo auditoría).

- Siempre pertenecen a un cliente que existe.
- Duplicado (bloquea): mismo cliente y mismo nombre normalizado. El mismo
  nombre en OTRO cliente es válido (hay dos "Carlos").
- Un contacto no cambia de cliente al editarlo (ContactUpdate no tiene
  client_id): moverlo cambiaría el cliente de sus actividades históricas.
"""
import sqlite3
from datetime import datetime

from core.formats import iso_now
from schemas.crm import ContactFields, ContactIn, ContactUpdate
from schemas.issues import Candidate, Issue, issue
from services.entity_resolver import normalize_text
from services.writes import NotFound, current_time, exists, raise_if_blocking, transaction


def contact_issues(conn: sqlite3.Connection, data: ContactFields, client_id: int | None, *,
                   exclude_id: int | None = None) -> list[Issue]:
    if client_id is None:
        return [issue("missing", "client", "Indica el cliente del contacto.")]
    if not exists(conn, "clients", client_id):
        return [issue("not_found", "client", "El cliente no existe.")]
    key = normalize_text(data.name)
    for row in conn.execute("SELECT id, nombre FROM contacts WHERE client_id = ? AND id IS NOT ?",
                            (client_id, exclude_id)).fetchall():
        if normalize_text(row["nombre"]) == key:
            return [issue("duplicate", "contact", f"{row['nombre']} ya es un contacto de este cliente.",
                          existing_id=row["id"], candidates=[Candidate(id=row["id"], label=row["nombre"])])]
    return []


def _row_out(conn, contact_id: int) -> dict:
    row = conn.execute("""
        SELECT ct.id, ct.client_id, c.razon_social AS client_name, ct.nombre, ct.cargo, ct.email, ct.telefono
        FROM contacts ct JOIN clients c ON c.id = ct.client_id WHERE ct.id = ?
    """, (contact_id,)).fetchone()
    return {"id": row["id"], "client_id": row["client_id"], "client_name": row["client_name"],
            "name": row["nombre"], "role": row["cargo"], "email": row["email"], "phone": row["telefono"]}


def create_contact(data: ContactIn, salesperson_id: int, *, conn: sqlite3.Connection | None = None,
                   now: datetime | None = None) -> dict:
    stamp = iso_now(now or current_time())
    with transaction(conn) as c:
        raise_if_blocking(contact_issues(c, data, data.client_id))
        contact_id = c.execute("""
            INSERT INTO contacts (client_id, nombre, cargo, telefono, email,
                                  created_by_salesperson_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (data.client_id, data.name, data.role, data.phone, data.email, salesperson_id, stamp, stamp)).lastrowid
        return _row_out(c, contact_id)


def update_contact(contact_id: int, data: ContactUpdate, salesperson_id: int, *,
                   conn: sqlite3.Connection | None = None, now: datetime | None = None) -> dict:
    stamp = iso_now(now or current_time())
    with transaction(conn) as c:
        row = c.execute("SELECT client_id FROM contacts WHERE id = ?", (contact_id,)).fetchone()
        if row is None:
            raise NotFound("Contacto no encontrado")
        raise_if_blocking(contact_issues(c, data, row["client_id"], exclude_id=contact_id))
        c.execute("""
            UPDATE contacts SET nombre = ?, cargo = ?, telefono = ?, email = ?, updated_at = ? WHERE id = ?
        """, (data.name, data.role, data.phone, data.email, stamp, contact_id))
        return _row_out(c, contact_id)
