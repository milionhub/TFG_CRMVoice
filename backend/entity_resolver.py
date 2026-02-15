from db import get_connection


def resolve_client(name: str):
    if not name:
        return None

    conn = get_connection()
    cur = conn.cursor()

    cur.execute("""
        SELECT id FROM clients
        WHERE LOWER(alias) = LOWER(?)
           OR LOWER(razon_social) = LOWER(?)
        LIMIT 1
    """, (name, name))

    row = cur.fetchone()
    conn.close()

    return row["id"] if row else None


def resolve_activity_type(action: str):
    if not action:
        return None

    conn = get_connection()
    cur = conn.cursor()

    cur.execute("""
        SELECT id FROM activity_types
        WHERE LOWER(accion) = LOWER(?)
        LIMIT 1
    """, (action,))

    row = cur.fetchone()
    conn.close()

    return row["id"] if row else None
