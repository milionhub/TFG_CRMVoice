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
