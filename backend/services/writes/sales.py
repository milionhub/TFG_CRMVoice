"""
Ventas (H.2): una fila = una línea de venta, del comercial autenticado.

- Alta de 1 a 5 líneas en UNA transacción: se valida todo antes de escribir
  y, si algo falla, no queda ninguna línea (nunca una venta a medias).
- Importe TOTAL de la línea en céntimos (int). El precio de catálogo del
  producto es solo informativo: nunca sustituye al importe indicado.
- Cliente obligatorio; contacto opcional y DEL cliente; producto existente o
  concepto libre; fecha "YYYY-MM-DD" no futura (una venta es un hecho).
- Las ventas de otro comercial no existen para este (404 igual que inexistente).
Las facturas históricas no se tocan (ver la vista revenue_lines).
"""
import sqlite3
from datetime import date, datetime

from core.formats import iso_now
from schemas.crm import SaleCreate, SaleLineIn, SaleUpdate
from schemas.issues import Issue, issue
from services.writes import NotFound, contact_issue, current_time, exists, raise_if_blocking, transaction


def _header_issues(conn, client_id: int, contact_id: int | None, sale_date: str, today: date) -> list[Issue]:
    issues = []
    if not exists(conn, "clients", client_id):
        issues.append(issue("not_found", "client", "El cliente no existe."))
    elif (problem := contact_issue(conn, client_id, contact_id)) is not None:
        issues.append(problem)
    if sale_date > today.isoformat():
        issues.append(issue("invalid", "sale_date", "La fecha de una venta no puede ser futura."))
    return issues


def _line_issues(conn, line: SaleLineIn | SaleUpdate, prefix: str) -> list[Issue]:
    if line.product_id is not None:
        if not exists(conn, "products", line.product_id):
            return [issue("not_found", f"{prefix}product", "El producto no existe.")]
    elif not line.concept:
        return [issue("missing", f"{prefix}product", "Indica un producto o un concepto.")]
    return []


def sale_issues(conn: sqlite3.Connection, data: SaleCreate, now: datetime) -> list[Issue]:
    today = now.date()
    issues = _header_issues(conn, data.client_id, data.contact_id, data.sale_date or today.isoformat(), today)
    for index, line in enumerate(data.lines):
        issues += _line_issues(conn, line, f"lines[{index}].")
    return issues


def sale_out(conn: sqlite3.Connection, sale_id: int) -> dict:
    row = conn.execute("""
        SELECT s.id, s.client_id, c.razon_social AS client_name, s.contact_id, ct.nombre AS contact_name,
               s.product_id, p.nombre AS product_name, s.concept, s.quantity, s.amount_cents, s.sale_date,
               s.notes, s.created_at, s.updated_at
        FROM sales s
        JOIN clients c ON c.id = s.client_id
        LEFT JOIN contacts ct ON ct.id = s.contact_id
        LEFT JOIN products p ON p.id = s.product_id
        WHERE s.id = ?
    """, (sale_id,)).fetchone()
    return dict(row)


def _insert(conn, salesperson_id, client_id, contact_id, sale_date, line, notes, stamp) -> int:
    return conn.execute("""
        INSERT INTO sales (salesperson_id, client_id, contact_id, product_id, quantity, amount_cents, sale_date,
                           concept, notes, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (salesperson_id, client_id, contact_id, line.product_id, line.quantity, line.amount_cents, sale_date,
          line.concept, notes, stamp, stamp)).lastrowid


def create_sales(data: SaleCreate, salesperson_id: int, *, conn: sqlite3.Connection | None = None,
                 now: datetime | None = None) -> list[dict]:
    """Todas las líneas o ninguna. Devuelve las ventas creadas, en el orden de las líneas."""
    now = now or current_time()
    sale_date = data.sale_date or now.date().isoformat()
    stamp = iso_now(now)
    with transaction(conn) as c:
        raise_if_blocking(sale_issues(c, data, now))
        ids = [_insert(c, salesperson_id, data.client_id, data.contact_id, sale_date, line, data.notes, stamp)
               for line in data.lines]
        return [sale_out(c, sale_id) for sale_id in ids]


def _owned(conn, sale_id: int, salesperson_id: int) -> None:
    if conn.execute("SELECT 1 FROM sales WHERE id = ? AND salesperson_id = ?",
                    (sale_id, salesperson_id)).fetchone() is None:
        raise NotFound("Venta no encontrada")


def update_sale(sale_id: int, data: SaleUpdate, salesperson_id: int, *, conn: sqlite3.Connection | None = None,
                now: datetime | None = None) -> dict:
    now = now or current_time()
    with transaction(conn) as c:
        _owned(c, sale_id, salesperson_id)
        issues = _header_issues(c, data.client_id, data.contact_id, data.sale_date, now.date())
        raise_if_blocking(issues + _line_issues(c, data, ""))
        c.execute("""
            UPDATE sales SET client_id = ?, contact_id = ?, product_id = ?, quantity = ?, amount_cents = ?,
                             sale_date = ?, concept = ?, notes = ?, updated_at = ?
            WHERE id = ? AND salesperson_id = ?
        """, (data.client_id, data.contact_id, data.product_id, data.quantity, data.amount_cents, data.sale_date,
              data.concept, data.notes, iso_now(now), sale_id, salesperson_id))
        return sale_out(c, sale_id)


def delete_sale(sale_id: int, salesperson_id: int, *, conn: sqlite3.Connection | None = None) -> None:
    with transaction(conn) as c:
        _owned(c, sale_id, salesperson_id)
        c.execute("DELETE FROM sales WHERE id = ? AND salesperson_id = ?", (sale_id, salesperson_id))


def list_sales(conn: sqlite3.Connection, salesperson_id: int, *, client_id: int | None = None,
               date_from: str | None = None, date_to: str | None = None, limit: int = 200) -> list[dict]:
    """Solo las ventas del comercial (más recientes primero)."""
    conditions, params = ["s.salesperson_id = ?"], [salesperson_id]
    if client_id is not None:
        conditions.append("s.client_id = ?")
        params.append(client_id)
    if date_from:
        conditions.append("s.sale_date >= ?")
        params.append(date_from)
    if date_to:
        conditions.append("s.sale_date <= ?")
        params.append(date_to)
    ids = [r["id"] for r in conn.execute(
        f"SELECT s.id FROM sales s WHERE {' AND '.join(conditions)} ORDER BY s.sale_date DESC, s.id DESC LIMIT ?",
        (*params, limit)).fetchall()]
    return [sale_out(conn, sale_id) for sale_id in ids]
