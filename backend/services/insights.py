"""
Insights del CRM para el chat (antes crm_insights_service, activity_intelligence
y opportunity_engine; unidos en E.3 sin cambiar el código).
"""
from db import get_connection


def analyze_activity_levels(salesperson_id: int):

    conn = get_connection()
    cursor = conn.cursor()

    # El filtro va en el ON (no en WHERE) para conservar los clientes
    # sin actividades de este comercial (LEFT JOIN → total 0)
    cursor.execute("""
        SELECT
            c.razon_social,
            COUNT(a.id) as total_activities
        FROM clients c
        LEFT JOIN activities a
            ON c.id = a.client_id AND a.salesperson_id = ?
        GROUP BY c.id
        ORDER BY total_activities DESC
    """, (salesperson_id,))

    rows = cursor.fetchall()

    insights = []

    for r in rows:

        client = r["razon_social"]
        total = r["total_activities"]

        if total >= 5:
            insights.append(
                f"{client} tiene alta actividad comercial reciente."
            )

        elif total == 0:
            insights.append(
                f"{client} no tiene actividad registrada."
            )

    conn.close()

    return insights


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


def detect_opportunities(context):

    insights = []

    total_activities = context["total_activities"]
    billing = context["billing"]

    total_facturado = billing["total_facturado"]
    ticket_medio = billing["ticket_medio"]

    # ----------------------------
    # Mucha actividad pero poca facturación
    # ----------------------------

    if total_activities > 10 and total_facturado < 2000:
        insights.append(
            "Alta actividad comercial pero baja facturación. Puede existir una oportunidad de conversión o upsell."
        )

    # ----------------------------
    # Cliente estratégico
    # ----------------------------

    if total_facturado > 20000:
        insights.append(
            "Cliente estratégico por volumen de facturación. Priorizar seguimiento y fidelización."
        )

    # ----------------------------
    # Ticket medio bajo
    # ----------------------------

    if ticket_medio < 200 and total_facturado > 0:
        insights.append(
            "Ticket medio bajo. Existe potencial para estrategias de upsell o cross-selling."
        )

    return insights
