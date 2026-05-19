from db import get_connection


def analyze_activity_levels():

    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT 
            c.razon_social,
            COUNT(a.id) as total_activities
        FROM clients c
        LEFT JOIN activities a ON c.id = a.client_id
        GROUP BY c.id
        ORDER BY total_activities DESC
    """)

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
