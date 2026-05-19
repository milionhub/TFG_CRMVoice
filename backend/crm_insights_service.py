from db import get_connection
from activity_intelligence import analyze_activity_levels



def get_crm_insights():

    conn = get_connection()
    cursor = conn.cursor()

    insights = {}

    # ---------------------------
    # Clientes con mayor facturación
    # ---------------------------

    cursor.execute("""
        SELECT c.razon_social, SUM(il.total) as total_facturado
        FROM clients c
        JOIN invoices i ON c.id = i.client_id
        JOIN invoice_lines il ON i.id = il.invoice_id
        GROUP BY c.razon_social
        ORDER BY total_facturado DESC
        LIMIT 3
    """)

    insights["top_clients"] = cursor.fetchall()

    # ---------------------------
    # Clientes sin actividad reciente
    # ---------------------------

    cursor.execute("""
        SELECT c.razon_social
        FROM clients c
        LEFT JOIN activities a ON c.id = a.client_id
        GROUP BY c.id
        HAVING MAX(a.datetime_iso) IS NULL
        OR MAX(a.datetime_iso) < date('now','-90 day')
        LIMIT 5
    """)

    insights["inactive_clients"] = cursor.fetchall()

    activity_insights = analyze_activity_levels()

    insights["activity_insights"] = activity_insights


    conn.close()

    return insights
