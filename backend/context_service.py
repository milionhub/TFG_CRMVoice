from db import get_connection
from opportunity_engine import detect_opportunities



def build_context(client_id: int):

    conn = get_connection()
    cursor = conn.cursor()

    # Nombre cliente
    cursor.execute("SELECT razon_social FROM clients WHERE id = ?", (client_id,))
    client_row = cursor.fetchone()
    client_name = client_row["razon_social"] if client_row else None

    # Total actividades
    cursor.execute("SELECT COUNT(*) as total FROM activities WHERE client_id = ?", (client_id,))
    total_activities = cursor.fetchone()["total"]

    # Última fecha contacto
    cursor.execute("""
        SELECT MAX(datetime_iso) as last_date
        FROM activities
        WHERE client_id = ?
    """, (client_id,))
    last_contact_date = cursor.fetchone()["last_date"]

    # Tipo actividad más frecuente
    cursor.execute("""
        SELECT at.accion, COUNT(*) as total
        FROM activities a
        JOIN activity_types at ON a.activity_type_id = at.id
        WHERE a.client_id = ?
        GROUP BY at.accion
        ORDER BY total DESC
        LIMIT 1
    """, (client_id,))
    row = cursor.fetchone()
    frequent_activity_type = row["accion"] if row else None

    # Últimas 5 actividades
    cursor.execute("""
        SELECT comentario
        FROM activities
        WHERE client_id = ?
        ORDER BY id DESC
        LIMIT 5
    """, (client_id,))
    recent_activities = [r["comentario"] for r in cursor.fetchall()]

    conn.close()

    # 🔥 AQUÍ VA EL PASO 2
    billing_data = get_client_billing_summary(client_id)

    return {
        "client_name": client_name,
        "total_activities": total_activities,
        "last_contact_date": last_contact_date,
        "frequent_activity_type": frequent_activity_type,
        "recent_activities": recent_activities,

        # 🔥 NUEVO BLOQUE FINANCIERO
        "billing": billing_data
    }

def get_client_billing_summary(client_id: int):
    conn = get_connection()
    cur = conn.cursor()

    # Total histórico
    cur.execute("""
        SELECT 
            SUM(il.total) as total_facturado,
            COUNT(DISTINCT i.id) as total_facturas,
            MAX(i.fecha) as ultima_factura
        FROM invoices i
        JOIN invoice_lines il ON i.id = il.invoice_id
        WHERE i.client_id = ?
    """, (client_id,))
    
    row = cur.fetchone()

    total_facturado = row["total_facturado"] or 0
    total_facturas = row["total_facturas"] or 0
    ultima_factura = row["ultima_factura"]

    ticket_medio = 0
    if total_facturas > 0:
        ticket_medio = round(total_facturado / total_facturas, 2)

    # Producto más facturado
    cur.execute("""
        SELECT p.nombre, SUM(il.total) as total_producto
        FROM invoices i
        JOIN invoice_lines il ON i.id = il.invoice_id
        JOIN products p ON p.id = il.product_id
        WHERE i.client_id = ?
        GROUP BY p.nombre
        ORDER BY total_producto DESC
        LIMIT 1
    """, (client_id,))

    prod_row = cur.fetchone()
    producto_top = prod_row["nombre"] if prod_row else None

    conn.close()

    return {
        "total_facturado": total_facturado,
        "total_facturas": total_facturas,
        "ultima_factura": ultima_factura,
        "ticket_medio": ticket_medio,
        "producto_top": producto_top
    }