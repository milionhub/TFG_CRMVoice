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
- attention (G.4): señales deterministas por cliente para decidir a quién
  revisar. Universo: TODOS los clientes del catálogo (también los que el
  comercial nunca ha contactado). Actividad: solo la DEL comercial;
  facturación: global. No hay puntuación oculta: cada cliente lleva sus
  señales y el orden se explica en "rules" (ATTENTION_RULES).
- product_discussed (G.4): productos más tratados en actividades DEL
  comercial (activity_products). Orden: actividades desc, clientes desc,
  nombre, id.
"""
import math
from datetime import datetime, timedelta

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


ATTENTION_INACTIVE_DAYS = 90
ATTENTION_ACTIVITY_WINDOW_DAYS = 90

ATTENTION_RULES = (
    "Señales del CRM, no una puntuación. never_contacted: no tienes ninguna actividad con el cliente. "
    f"inactive_90d: tu última actividad pasada con él fue hace más de {ATTENTION_INACTIVE_DAYS} días. "
    "no_upcoming: no tienes ninguna actividad próxima con él. "
    "top_billing: está en el tercio superior por facturación total (global, todos los comerciales) "
    "de los clientes que facturan. "
    "top_billing_low_attention: top_billing y además never_contacted o inactive_90d. "
    "Orden: más señales primero; después top_billing_low_attention; después más días sin actividad "
    "(nunca contactados primero); después más facturación; después nombre."
)


def _attention(conn, salesperson_id, limit, now):
    current = iso_now(now)
    window_start = iso_now(now - timedelta(days=ATTENTION_ACTIVITY_WINDOW_DAYS))

    # Filtro del comercial en el ON: los clientes sin actividades suyas siguen apareciendo
    rows = conn.execute("""
        SELECT c.id, c.razon_social,
               COUNT(a.id) AS own_total,
               MAX(CASE WHEN a.datetime_iso < ? THEN a.datetime_iso END) AS last_past,
               MIN(CASE WHEN a.datetime_iso >= ? THEN a.datetime_iso END) AS next_upcoming,
               COALESCE(SUM(CASE WHEN a.datetime_iso >= ? AND a.datetime_iso < ? THEN 1 ELSE 0 END), 0) AS recent
        FROM clients c
        LEFT JOIN activities a ON a.client_id = c.id AND a.salesperson_id = ?
        GROUP BY c.id
    """, (current, current, window_start, current, salesperson_id)).fetchall()

    # Facturación GLOBAL por cliente (las facturas no tienen propietario)
    billing = {r["client_id"]: (r["total"] or 0, r["last_date"]) for r in conn.execute("""
        SELECT i.client_id, SUM(il.total) AS total, MAX(i.fecha) AS last_date
        FROM invoices i
        JOIN invoice_lines il ON il.invoice_id = i.id
        GROUP BY i.client_id
    """).fetchall()}

    # Tercio superior (redondeando hacia arriba) de los clientes con facturación > 0
    billed = sorted((r for r in rows if billing.get(r["id"], (0, None))[0] > 0),
                    key=lambda r: (-billing[r["id"]][0], r["razon_social"], r["id"]))
    top_billing = {r["id"] for r in billed[:math.ceil(len(billed) / 3)]}

    items = []
    for r in rows:
        total_billed, last_invoice = billing.get(r["id"], (0, None))
        days = (None if r["last_past"] is None
                else (now.date() - datetime.fromisoformat(r["last_past"][:19]).date()).days)
        never = r["own_total"] == 0
        inactive = days is not None and days > ATTENTION_INACTIVE_DAYS
        signals = []
        if never:
            signals.append("never_contacted")
        if inactive:
            signals.append("inactive_90d")
        if r["next_upcoming"] is None:
            signals.append("no_upcoming")
        if r["id"] in top_billing:
            signals.append("top_billing")
            if never or inactive:
                signals.append("top_billing_low_attention")
        items.append({
            "client": {"id": r["id"], "name": r["razon_social"]},
            "last_past_activity_datetime": r["last_past"],
            "days_since_last_activity": days,
            "next_activity_datetime": r["next_upcoming"],
            "activities_last_90_days": r["recent"],
            "total_billed": total_billed,
            "last_invoice_date": last_invoice,
            "signals": signals,
        })

    items.sort(key=lambda i: (
        -len(i["signals"]),
        "top_billing_low_attention" not in i["signals"],
        i["days_since_last_activity"] is not None,      # sin actividad pasada (p. ej. nunca contactado) primero
        -(i["days_since_last_activity"] or 0),
        -i["total_billed"],
        i["client"]["name"],
        i["client"]["id"],
    ))
    return {"scope": {"activity": "salesperson", "billing": "global"}, "rules": ATTENTION_RULES,
            "clients_considered": len(items), "items": items[:limit]}


def _product_discussed(conn, salesperson_id, limit, now):
    rows = conn.execute("""
        SELECT p.id, p.nombre, COUNT(DISTINCT a.id) AS activities, COUNT(DISTINCT a.client_id) AS clients,
               MAX(a.datetime_iso) AS last_date
        FROM activity_products ap
        JOIN activities a ON a.id = ap.activity_id
        JOIN products p ON p.id = ap.product_id
        WHERE a.salesperson_id = ?
        GROUP BY p.id
        ORDER BY activities DESC, clients DESC, p.nombre, p.id
        LIMIT ?
    """, (salesperson_id, limit)).fetchall()
    return {"scope": "salesperson", "items": [
        {"product": {"name": r["nombre"]}, "activity_count": r["activities"], "client_count": r["clients"],
         "last_activity_datetime": r["last_date"]}
        for r in rows
    ]}


# Allowlist: la métrica elige una función, no una columna ni un fragmento SQL
METRICS = {
    "activity_count": _activity_count,
    "inactivity": _inactivity,
    "billing": _billing,
    "attention": _attention,
    "product_discussed": _product_discussed,
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
