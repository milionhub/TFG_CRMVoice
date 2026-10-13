"""
Ficha de cliente (GET /clients/{id}, H.2): lo que necesita la futura pantalla
de cliente, sin sobredimensionar.

- Cliente y contactos: compartidos (cualquier comercial los ve).
- Actividades y ventas: SOLO las del comercial autenticado.
- Ingresos con su origen: facturas históricas (globales, sin comercial) y las
  ventas del comercial, por separado y sumadas; nunca las ventas de otros.
- Productos tratados en las actividades del comercial (crm_tools).
Solo lectura (conexión query_only).
"""
from services.crm_tools._common import open_connection
from services.crm_tools.products import discussed_products
from services.writes.clients import get_client
from services.writes.sales import list_sales

RECENT_ACTIVITIES = 10
RECENT_SALES = 20


def client_detail(client_id: int, salesperson_id: int) -> dict:
    with open_connection() as conn:
        client = get_client(conn, client_id)   # NotFound -> 404
        contacts = [dict(r) for r in conn.execute("""
            SELECT id, nombre AS name, cargo AS role, email, telefono AS phone
            FROM contacts WHERE client_id = ? ORDER BY nombre, id
        """, (client_id,)).fetchall()]
        activities = [dict(r) for r in conn.execute("""
            SELECT a.id, a.datetime_iso AS datetime, a.status, t.accion AS activity_type,
                   ct.nombre AS contact_name, a.comentario AS comment
            FROM activities a
            LEFT JOIN activity_types t ON t.id = a.activity_type_id
            LEFT JOIN contacts ct ON ct.id = a.contact_id
            WHERE a.client_id = ? AND a.salesperson_id = ?
            ORDER BY a.datetime_iso DESC, a.id DESC LIMIT ?
        """, (client_id, salesperson_id, RECENT_ACTIVITIES)).fetchall()]
        invoices = conn.execute("""
            SELECT COALESCE(SUM(amount_cents), 0) AS total, COUNT(*) AS lines
            FROM revenue_lines WHERE source = 'invoice' AND client_id = ?
        """, (client_id,)).fetchone()
        my_sales = conn.execute("""
            SELECT COALESCE(SUM(amount_cents), 0) AS total, COUNT(*) AS lines
            FROM revenue_lines WHERE source = 'sale' AND client_id = ? AND salesperson_id = ?
        """, (client_id, salesperson_id)).fetchone()
        sales = list_sales(conn, salesperson_id, client_id=client_id, limit=RECENT_SALES)
        products = discussed_products(conn, client_id, salesperson_id)

    return {
        "client": client,
        "contacts": contacts,
        "recent_activities": activities,
        "sales": sales,
        "revenue": {
            "invoices_cents": invoices["total"], "invoice_lines": invoices["lines"],
            "my_sales_cents": my_sales["total"], "my_sales_lines": my_sales["lines"],
            "total_cents": invoices["total"] + my_sales["total"],
            "note": "Facturas históricas (globales) + tus ventas registradas en CRMVoice.",
        },
        "discussed_products": products,
    }
