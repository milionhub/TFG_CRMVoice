"""
Catálogo del CRM: productos, clientes, contactos y tipos de actividad.

Es GLOBAL, compartido por todos los comerciales: estas consultas no se
filtran por usuario. Lo privado son las actividades.
"""
from db import get_connection
from services.entity_resolver import normalize_text


def list_products() -> list[dict]:
    """
    Catálogo de productos (id, name, price), por nombre. Es la ÚNICA lista de
    productos de la app: la usan los selectores de actividades y ventas y la
    pantalla Productos (I.8), así que un producto nuevo aparece en todas.
    """
    conn = get_connection()
    try:
        rows = conn.execute("SELECT id, nombre, precio FROM products ORDER BY nombre ASC").fetchall()
    finally:
        conn.close()
    return [{"id": r["id"], "name": r["nombre"], "price": r["precio"]} for r in rows]


def list_clients(q: str | None = None) -> list[dict]:
    """
    Todos los clientes, o los que contienen `q` en la razón social o el alias
    (sin tildes ni mayúsculas). Mismos campos de siempre (id, name): el detalle
    está en GET /clients/{id}.
    """
    conn = get_connection()
    try:
        rows = conn.execute("""
            SELECT id, razon_social, alias
            FROM clients
            ORDER BY razon_social ASC
        """).fetchall()
    finally:
        conn.close()

    needle = normalize_text(q) if q else ""
    return [
        {
            "id": r["id"],
            "name": r["razon_social"],
        }
        for r in rows
        if not needle or needle in normalize_text(r["razon_social"]) or needle in normalize_text(r["alias"] or "")
    ]


def list_contacts(client_id: int | None = None) -> list[dict]:
    """Contactos de un cliente o, sin client_id, todos (client_id=0 no es "todos")."""
    conn = get_connection()
    cursor = conn.cursor()

    if client_id is not None:
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
