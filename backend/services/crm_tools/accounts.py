"""
Vistas factuales de cliente y contacto, y datos para preparar una reunión.

Actividad: solo la DEL comercial indicado. Facturación y catálogo
(clientes, contactos, productos): globales por diseño, porque invoices no
tiene propietario efectivo en el CRM. Ninguna llama al LLM.
"""
from datetime import datetime

from services.crm_tools._common import (
    activity_summary, fetch_activities, iso_now, open_connection, resolve_now, validate_id,
)
from services.crm_tools.products import discussed_products, invoiced_products
from services.insights import detect_opportunities

MEETING_RECENT_LIMIT = 5
MEETING_UPCOMING_LIMIT = 5
CONTACT_RECENT_LIMIT = 5


def _client_row(conn, client_id: int):
    return conn.execute("""
        SELECT c.id, c.razon_social, c.alias, c.cif, c.direccion, c.codigo_postal, c.poblacion,
               c.provincia, c.pais, c.telefono, c.email, g.name AS group_name
        FROM clients c
        LEFT JOIN client_groups g ON g.id = c.group_id
        WHERE c.id = ?
    """, (client_id,)).fetchone()


def _client_data(row) -> dict:
    return {
        "id": row["id"], "name": row["razon_social"], "alias": row["alias"], "group": row["group_name"],
        "cif": row["cif"], "address": row["direccion"], "postal_code": row["codigo_postal"],
        "city": row["poblacion"], "province": row["provincia"], "country": row["pais"],
        "phone": row["telefono"], "email": row["email"],
    }


def _contacts(conn, client_id: int) -> list[dict]:
    rows = conn.execute("""
        SELECT id, nombre, cargo, telefono, email FROM contacts
        WHERE client_id = ? ORDER BY nombre, id
    """, (client_id,)).fetchall()
    return [{"id": r["id"], "name": r["nombre"], "role": r["cargo"], "phone": r["telefono"], "email": r["email"]}
            for r in rows]


def _billing(conn, client_id: int) -> dict:
    """Facturación GLOBAL del cliente (todas las facturas, de cualquier comercial)."""
    row = conn.execute("""
        SELECT COALESCE(SUM(il.total), 0) AS total, COUNT(DISTINCT i.id) AS invoices, MAX(i.fecha) AS last_date
        FROM invoices i
        JOIN invoice_lines il ON il.invoice_id = i.id
        WHERE i.client_id = ?
    """, (client_id,)).fetchone()
    top = invoiced_products(conn, client_id, limit=1)
    return {
        "scope": "global",
        "total_billed": row["total"],
        "invoice_count": row["invoices"],
        "average_ticket": round(row["total"] / row["invoices"], 2) if row["invoices"] else None,
        "last_invoice_date": row["last_date"],
        "top_product": {k: top[0][k] for k in ("id", "name", "total_billed")} if top else None,
    }


def _overview(conn, client_id: int, salesperson_id: int, now: datetime):
    row = _client_row(conn, client_id)
    if row is None:
        return None
    return {
        "found": True,
        "now": now.isoformat(),
        "client": _client_data(row),
        "contacts": _contacts(conn, client_id),
        "activity": activity_summary(conn, salesperson_id, now, client_id=client_id),
        "billing": _billing(conn, client_id),
        "products": {
            "discussed": discussed_products(conn, client_id, salesperson_id),
            "invoiced": invoiced_products(conn, client_id),
        },
    }


def get_client_overview(client_id: int, salesperson_id: int, *, now: datetime | None = None) -> dict:
    """Datos del cliente, contactos, actividad DEL comercial, facturación global y productos con evidencia."""
    client_id = validate_id(client_id, "client_id")
    now = resolve_now(now)
    with open_connection() as conn:
        overview = _overview(conn, client_id, salesperson_id, now)
    return overview or {"found": False, "client_id": client_id}


def get_contact(contact_id: int, salesperson_id: int, *, now: datetime | None = None) -> dict:
    """Contacto, su cliente y la actividad DEL comercial con ese contacto."""
    contact_id = validate_id(contact_id, "contact_id")
    now = resolve_now(now)

    with open_connection() as conn:
        row = conn.execute("""
            SELECT ct.id, ct.nombre, ct.cargo, ct.telefono, ct.email, c.id AS client_id, c.razon_social
            FROM contacts ct
            JOIN clients c ON c.id = ct.client_id
            WHERE ct.id = ?
        """, (contact_id,)).fetchone()
        if row is None:
            return {"found": False, "contact_id": contact_id}

        summary = activity_summary(conn, salesperson_id, now, contact_id=contact_id)
        recent, _ = fetch_activities(conn, salesperson_id,
                                     [("a.contact_id = ?", contact_id), ("a.datetime_iso < ?", iso_now(now))],
                                     order="desc", limit=CONTACT_RECENT_LIMIT, now=now)

    return {
        "found": True,
        "now": now.isoformat(),
        "contact": {"id": row["id"], "name": row["nombre"], "role": row["cargo"],
                    "phone": row["telefono"], "email": row["email"]},
        "client": {"id": row["client_id"], "name": row["razon_social"]},
        "activity": summary,
        "recent_activities": recent,
    }


def prepare_meeting_context(client_id: int, salesperson_id: int, *, now: datetime | None = None) -> dict:
    """
    Datos estructurados para que el LLM redacte (en G.3) un briefing de
    reunión: la vista del cliente más las últimas actividades pasadas, las
    próximas y las señales de las reglas existentes. No llama al LLM.
    """
    client_id = validate_id(client_id, "client_id")
    now = resolve_now(now)

    with open_connection() as conn:
        context = _overview(conn, client_id, salesperson_id, now)
        if context is None:
            return {"found": False, "client_id": client_id}
        current = iso_now(now)
        by_client = ("a.client_id = ?", client_id)
        recent, _ = fetch_activities(conn, salesperson_id, [by_client, ("a.datetime_iso < ?", current)],
                                     order="desc", limit=MEETING_RECENT_LIMIT, now=now)
        upcoming, _ = fetch_activities(conn, salesperson_id, [by_client, ("a.datetime_iso >= ?", current)],
                                       order="asc", limit=MEETING_UPCOMING_LIMIT, now=now)

    last = context["activity"]["last_activity"]
    billing = context["billing"]
    # Reglas deterministas existentes (services.insights), con sus mismos datos:
    # actividad del comercial y facturación global. Son umbrales fijos, no análisis.
    signals = detect_opportunities({
        "total_activities": context["activity"]["total"],
        "billing": {"total_facturado": billing["total_billed"], "ticket_medio": billing["average_ticket"] or 0},
    })

    return {
        **context,
        "last_contact_datetime": last["datetime"] if last else None,
        "recent_activities": recent,
        "upcoming_activities": upcoming,
        "rule_signals": [{"source": "insights.detect_opportunities", "text": s} for s in signals],
    }
