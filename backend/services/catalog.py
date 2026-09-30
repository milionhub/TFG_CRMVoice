"""
Catálogo del CRM: productos, clientes, contactos y tipos de actividad.

Es GLOBAL, compartido por todos los comerciales: estas consultas no se
filtran por usuario. Lo privado son las actividades.
"""
from db import get_connection


def list_products() -> list[dict]:
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, nombre, precio
        FROM products
        ORDER BY nombre ASC
    """)

    rows = cursor.fetchall()
    conn.close()

    return [
        {
            "id": r["id"],
            "name": r["nombre"],
            "price": r["precio"]
        }
        for r in rows
    ]


def list_clients() -> list[dict]:
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, razon_social
        FROM clients
        ORDER BY razon_social ASC
    """)

    rows = cursor.fetchall()
    conn.close()

    return [
        {
            "id": r["id"],
            "name": r["razon_social"]
        }
        for r in rows
    ]


def list_contacts(client_id: int | None = None) -> list[dict]:
    """Contactos de un cliente o, sin client_id (o con 0), todos."""
    conn = get_connection()
    cursor = conn.cursor()

    if client_id:
        cursor.execute("""
            SELECT id, nombre
            FROM contacts
            WHERE client_id = ?
            ORDER BY nombre ASC
        """, (client_id,))
    else:
        cursor.execute("""
            SELECT id, nombre
            FROM contacts
            ORDER BY nombre ASC
        """)

    rows = cursor.fetchall()
    conn.close()

    return [
        {
            "id": r["id"],
            "name": r["nombre"]
        }
        for r in rows
    ]


def list_activity_types() -> list[dict]:
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, accion
        FROM activity_types
        ORDER BY accion ASC
    """)

    rows = cursor.fetchall()
    conn.close()

    return [
        {
            "id": r["id"],
            "name": r["accion"]
        }
        for r in rows
    ]
