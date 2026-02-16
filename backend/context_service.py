from db import get_connection


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
        SELECT MAX(fecha_iso) as last_date
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

    # Últimas 5 actividades (comentarios)
    cursor.execute("""
        SELECT comentario
        FROM activities
        WHERE client_id = ?
        ORDER BY id DESC
        LIMIT 5
    """, (client_id,))
    recent_activities = [r["comentario"] for r in cursor.fetchall()]

    conn.close()

    return {
        "client_name": client_name,
        "total_activities": total_activities,
        "last_contact_date": last_contact_date,
        "frequent_activity_type": frequent_activity_type,
        "billing_total": 0,  # lo mejoramos luego
        "recent_activities": recent_activities
    }
