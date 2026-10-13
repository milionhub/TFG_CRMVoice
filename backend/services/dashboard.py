"""
Métricas de Home (H.5.2): solo datos DEL comercial autenticado, en pocas
consultas agregadas sobre SQLite (índice idx_activities_owner_status).

Referencia temporal: la hora local del servidor (services.writes.current_time),
la misma que usan las escrituras, los borradores y el chat.

- pending:   actividades pendientes (incluidas las vencidas);
- overdue:   pendientes cuya fecha y hora ya pasó;
- upcoming:  pendientes de ahora en adelante (y las de los próximos 7 días);
- next:      las próximas pendientes, con lo necesario para mostrarlas;
- sales_month: ventas registradas por el comercial este mes (revenue_lines,
  source = 'sale'), en céntimos exactos. Las facturas históricas no cuentan.
Las canceladas no cuentan en nada. Solo lectura.
"""
from datetime import datetime, timedelta

from core.formats import iso_now
from db import connection
from services.crm_tools.sales import month_bounds
from services.writes import current_time

NEXT_LIMIT = 5
UPCOMING_WINDOW_DAYS = 7


def dashboard(salesperson_id: int, *, now: datetime | None = None) -> dict:
    now = now or current_time()
    current = iso_now(now)
    window_end = iso_now(now + timedelta(days=UPCOMING_WINDOW_DAYS))
    month_from, month_to = month_bounds(now)

    with connection() as conn:
        counts = conn.execute("""
            SELECT COUNT(*) AS pending,
                   COALESCE(SUM(datetime_iso < ?), 0) AS overdue,
                   COALESCE(SUM(datetime_iso >= ?), 0) AS upcoming,
                   COALESCE(SUM(datetime_iso >= ? AND datetime_iso < ?), 0) AS upcoming_7d
            FROM activities
            WHERE salesperson_id = ? AND status = 'pending'
        """, (current, current, current, window_end, salesperson_id)).fetchone()
        next_rows = conn.execute("""
            SELECT a.id, a.datetime_iso, a.client_id, c.razon_social AS client_name,
                   ct.nombre AS contact_name, t.accion AS activity_type
            FROM activities a
            LEFT JOIN clients c ON c.id = a.client_id
            LEFT JOIN contacts ct ON ct.id = a.contact_id
            LEFT JOIN activity_types t ON t.id = a.activity_type_id
            WHERE a.salesperson_id = ? AND a.status = 'pending' AND a.datetime_iso >= ?
            ORDER BY a.datetime_iso ASC, a.id ASC
            LIMIT ?
        """, (salesperson_id, current, NEXT_LIMIT)).fetchall()
        sales = conn.execute("""
            SELECT COALESCE(SUM(amount_cents), 0) AS total, COUNT(*) AS lines
            FROM revenue_lines
            WHERE source = 'sale' AND salesperson_id = ? AND day >= ? AND day <= ?
        """, (salesperson_id, month_from, month_to)).fetchone()

    return {
        "now": current,
        "activities": {
            "pending": counts["pending"],
            "overdue": counts["overdue"],
            "upcoming": counts["upcoming"],
            "upcoming_7d": counts["upcoming_7d"],
        },
        "next_activities": [
            {"id": r["id"], "datetime": r["datetime_iso"], "client_id": r["client_id"],
             "client_name": r["client_name"], "contact_name": r["contact_name"],
             "activity_type": r["activity_type"], "status": "pending"}
            for r in next_rows
        ],
        "sales_month": {
            "month": month_from[:7],
            "date_from": month_from,
            "date_to": month_to,
            "total_cents": sales["total"],
            "line_count": sales["lines"],
        },
    }
