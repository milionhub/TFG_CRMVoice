from db import get_connection
from activity_intelligence import analyze_activity_levels



def get_crm_insights(salesperson_id: int):
    """
    Las actividades se limitan a las del comercial autenticado.
    La facturación es común a todo el CRM (invoices no tiene propietario asignado).
    """

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

    # Filtro en el ON (no en WHERE): un cliente sin actividades de este
    # comercial debe seguir apareciendo como inactivo
    cursor.execute("""
        SELECT c.razon_social
        FROM clients c
        LEFT JOIN activities a
            ON c.id = a.client_id AND a.salesperson_id = ?
        GROUP BY c.id
        HAVING MAX(a.datetime_iso) IS NULL
        OR MAX(a.datetime_iso) < date('now','-90 day')
        LIMIT 5
    """, (salesperson_id,))

    insights["inactive_clients"] = cursor.fetchall()

    activity_insights = analyze_activity_levels(salesperson_id)

    insights["activity_insights"] = activity_insights


    conn.close()

    return insights
