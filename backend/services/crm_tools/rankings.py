"""
Rankings de clientes con métricas cerradas (el caller elige una clave, nunca SQL):

- activity_count: clientes con más actividades DEL comercial (pasadas y
  próximas). Solo clientes con al menos una. Orden: recuento desc, nombre, id.
- inactivity: clientes con los que el comercial lleva más tiempo sin
  actividad. Universo: clientes con al menos una actividad DEL comercial.
  Inactividad = días desde su última actividad PASADA (datetime < ahora);
  un cliente que solo tiene actividades próximas (ninguna pasada) va primero
  (days_inactive = None). Orden: sin actividad pasada primero, después la
  última pasada más antigua; a igualdad, nombre e id. Los clientes del
  catálogo sin ninguna actividad del comercial no se listan: se cuentan en
  clients_without_activity.
- billing: clientes que más han facturado (GLOBAL: las facturas no tienen
  propietario). Solo clientes con facturación > 0. Orden: total desc, nombre, id.
"""
from datetime import datetime

from services.crm_tools._common import ToolArgumentError, iso_now, open_connection, resolve_now, validate_limit

DEFAULT_LIMIT = 5
MAX_LIMIT = 20


def _activity_count(conn, salesperson_id, limit, now):
    rows = conn.execute("""
        SELECT c.id, c.razon_social, COUNT(a.id) AS total, MAX(a.datetime_iso) AS last_date
        FROM activities a
        JOIN clients c ON c.id = a.client_id
        WHERE a.salesperson_id = ?
        GROUP BY c.id
        ORDER BY total DESC, c.razon_social, c.id
        LIMIT ?
    """, (salesperson_id, limit)).fetchall()
    return {"scope": "salesperson", "items": [
        {"client": {"id": r["id"], "name": r["razon_social"]}, "activity_count": r["total"],
         "latest_activity_datetime": r["last_date"]}
        for r in rows
    ]}


def _inactivity(conn, salesperson_id, limit, now):
    current = iso_now(now)
    rows = conn.execute("""
        SELECT c.id, c.razon_social,
               MAX(CASE WHEN a.datetime_iso < ? THEN a.datetime_iso END) AS last_past,
               MIN(CASE WHEN a.datetime_iso >= ? THEN a.datetime_iso END) AS next_upcoming
        FROM activities a
        JOIN clients c ON c.id = a.client_id
        WHERE a.salesperson_id = ?
        GROUP BY c.id
        ORDER BY (last_past IS NOT NULL), last_past ASC, c.razon_social, c.id
        LIMIT ?
    """, (current, current, salesperson_id, limit)).fetchall()
    without = conn.execute("""
        SELECT COUNT(*) FROM clients c
        WHERE NOT EXISTS (SELECT 1 FROM activities a WHERE a.client_id = c.id AND a.salesperson_id = ?)
    """, (salesperson_id,)).fetchone()[0]

    def days_since(value):
        return None if value is None else (now.date() - datetime.fromisoformat(value[:19]).date()).days

    return {"scope": "salesperson", "clients_without_activity": without, "items": [
        {"client": {"id": r["id"], "name": r["razon_social"]}, "last_past_activity_datetime": r["last_past"],
         "days_inactive": days_since(r["last_past"]), "next_activity_datetime": r["next_upcoming"]}
        for r in rows
    ]}


def _billing(conn, salesperson_id, limit, now):
    rows = conn.execute("""
        SELECT c.id, c.razon_social, SUM(il.total) AS total, COUNT(DISTINCT i.id) AS invoices
        FROM invoices i
        JOIN invoice_lines il ON il.invoice_id = i.id
        JOIN clients c ON c.id = i.client_id
        GROUP BY c.id
        HAVING total > 0
        ORDER BY total DESC, c.razon_social, c.id
        LIMIT ?
    """, (limit,)).fetchall()
    return {"scope": "global", "items": [
        {"client": {"id": r["id"], "name": r["razon_social"]}, "total_billed": r["total"],
         "invoice_count": r["invoices"]}
        for r in rows
    ]}


# Allowlist: la métrica elige una función, no una columna ni un fragmento SQL
METRICS = {
    "activity_count": _activity_count,
    "inactivity": _inactivity,
    "billing": _billing,
}


def crm_rankings(metric: str, salesperson_id: int, *, limit: int | None = None,
                 now: datetime | None = None) -> dict:
    if not isinstance(metric, str) or metric not in METRICS:
        raise ToolArgumentError(f"metric debe ser una de: {', '.join(METRICS)}")
    limit = validate_limit(limit, DEFAULT_LIMIT, MAX_LIMIT)
    now = resolve_now(now)

    with open_connection() as conn:
        ranking = METRICS[metric](conn, salesperson_id, limit, now)

    return {"found": bool(ranking["items"]), "metric": metric, "now": now.isoformat(), **ranking}
