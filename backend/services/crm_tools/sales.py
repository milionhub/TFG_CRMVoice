"""
Ventas registradas en CRMVoice (H.2/H.3/H.4) para el chat: SOLO las del
comercial (nunca las de otro) y SIEMPRE separadas de la facturación histórica
(invoices), que es global y se consulta aparte (accounts._billing).

- Totales sobre la vista revenue_lines (source = 'sale'): importes en
  céntimos enteros; los euros se dan como texto exacto ("1500.00"), sin
  pasar por float.
- Líneas con services.writes.sales.list_sales (el mismo servicio que la API).
Solo lectura; ninguna llama al LLM.
"""
from datetime import datetime, timedelta

from schemas.crm import cents_to_text
from services.crm_tools._common import (
    ToolArgumentError, open_connection, parse_date, resolve_now, validate_id, validate_limit,
)
from services.writes.sales import list_sales as sale_rows

SALES_DEFAULT_LIMIT = 10
SALES_MAX_LIMIT = 50
SALES_SOURCE = "Ventas registradas por ti en CRMVoice (no incluye la facturación histórica)"


def euros(cents: int | None) -> str | None:
    """Céntimos -> "1500.00" exacto (texto, nunca float)."""
    return None if cents is None else cents_to_text(cents)


def sales_summary(conn, salesperson_id: int, *, client_id: int | None = None,
                  date_from: str | None = None, date_to: str | None = None) -> dict:
    """Total y número de líneas de las ventas DEL comercial (opcionalmente de un cliente y periodo)."""
    where, params = ["source = 'sale'", "salesperson_id = ?"], [salesperson_id]
    if client_id is not None:
        where.append("client_id = ?")
        params.append(client_id)
    if date_from:
        where.append("day >= ?")
        params.append(date_from)
    if date_to:
        where.append("day <= ?")
        params.append(date_to)
    row = conn.execute(f"""
        SELECT COALESCE(SUM(amount_cents), 0) AS total, COUNT(*) AS lines, MAX(day) AS last_day
        FROM revenue_lines WHERE {" AND ".join(where)}
    """, params).fetchone()
    return {"scope": "salesperson", "source": SALES_SOURCE, "total_cents": row["total"],
            "total_eur": euros(row["total"]), "line_count": row["lines"], "last_sale_date": row["last_day"]}


def list_sales(salesperson_id: int, *, client_id: int | None = None, date_from: str | None = None,
               date_to: str | None = None, limit: int | None = None, now: datetime | None = None) -> dict:
    """
    Ventas registradas DEL comercial: total exacto de TODAS las que cumplen
    los filtros y el detalle de las `limit` más recientes. date_from/date_to:
    días "YYYY-MM-DD" inclusivos.
    """
    client_id = validate_id(client_id, "client_id", optional=True)
    start = parse_date(date_from, "date_from")
    end = parse_date(date_to, "date_to")
    if start and end and start > end:
        raise ToolArgumentError("date_from no puede ser posterior a date_to")
    limit = validate_limit(limit, SALES_DEFAULT_LIMIT, SALES_MAX_LIMIT)
    now = resolve_now(now)
    day_from = start.isoformat() if start else None
    day_to = end.isoformat() if end else None

    with open_connection() as conn:
        summary = sales_summary(conn, salesperson_id, client_id=client_id, date_from=day_from, date_to=day_to)
        rows = sale_rows(conn, salesperson_id, client_id=client_id, date_from=day_from, date_to=day_to,
                         limit=limit)

    return {
        "found": bool(rows),
        "now": now.isoformat(),
        "filters": {"client_id": client_id, "date_from": day_from, "date_to": day_to},
        "summary": summary,
        "count": len(rows),
        "has_more": summary["line_count"] > len(rows),
        "sales": [
            {
                "date": r["sale_date"],
                "client": {"id": r["client_id"], "name": r["client_name"]},
                "contact": r["contact_name"],
                "item": r["product_name"] or r["concept"],
                "quantity": r["quantity"],
                "amount_cents": r["amount_cents"],
                "amount_eur": euros(r["amount_cents"]),
            }
            for r in rows
        ],
    }


def month_bounds(now: datetime) -> tuple[str, str]:
    """Primer y último día del mes de `now` ("YYYY-MM-DD")."""
    first = now.date().replace(day=1)
    next_month = (first + timedelta(days=32)).replace(day=1)
    return first.isoformat(), (next_month - timedelta(days=1)).isoformat()
