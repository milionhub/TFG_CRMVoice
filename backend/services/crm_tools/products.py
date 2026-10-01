"""
Productos con su fuente (source):
- "catalog":  existe en el catálogo global; no dice nada de ningún cliente;
- "activity": tratado en actividades DEL comercial con el cliente
  (activity_products: el producto se mencionó, no implica compra ni uso);
- "invoice":  facturado al cliente (invoice_lines; facturación global).
Las líneas de factura sin product_id no se pueden atribuir a un producto.
"""
from services.crm_tools._common import ToolArgumentError, open_connection, validate_id, validate_limit
from services.entity_resolver import normalize_text

CATALOG_DEFAULT_LIMIT = 20
CATALOG_MAX_LIMIT = 50
CLIENT_PRODUCTS_LIMIT = 20
PRODUCT_NAME_MAX_LENGTH = 100


def _catalog(conn):
    """Productos (orden nombre, id) y sus alias {product_id: [alias]}."""
    products = conn.execute("SELECT id, nombre, precio FROM products ORDER BY nombre, id").fetchall()
    aliases = {}
    for a in conn.execute("SELECT product_id, alias FROM product_aliases ORDER BY alias, id").fetchall():
        aliases.setdefault(a["product_id"], []).append(a["alias"])
    return products, aliases


def resolve_product(conn, product_name: str) -> dict:
    """
    Un producto del catálogo a partir del nombre o alias que diga el usuario
    (sin mayúsculas ni tildes). Nunca elige ante la ambigüedad:
    - coincidencia exacta con un nombre o alias de un solo producto → resolved;
    - si no, productos cuyo nombre o alias CONTIENE el texto: uno → resolved;
      varios → ambiguous (solo nombres); ninguno → unresolved.
    Devuelve {"status", "product": {"id", "name"} | None, "candidates": [nombres]}.
    """
    products, aliases = _catalog(conn)
    needle = normalize_text(product_name)
    if not needle:                       # solo signos de puntuación: no contiene nada útil
        return {"status": "unresolved", "product": None, "candidates": []}

    def names(p):
        return [normalize_text(n) for n in [p["nombre"], *aliases.get(p["id"], [])]]

    exact = [p for p in products if needle in names(p)]
    matches = exact or [p for p in products if any(needle in n for n in names(p))]

    if len(matches) == 1:
        return {"status": "resolved", "product": {"id": matches[0]["id"], "name": matches[0]["nombre"]},
                "candidates": []}
    return {"status": "ambiguous" if matches else "unresolved", "product": None,
            "candidates": [p["nombre"] for p in matches]}


def search_product_catalog(query: str | None = None, *, limit: int | None = None) -> dict:
    """
    Catálogo global. Con query: productos cuyo nombre o alias contiene el
    texto (sin mayúsculas ni tildes). Orden: nombre, id.
    """
    if query is not None and (not isinstance(query, str) or not query.strip()):
        raise ToolArgumentError("query debe ser un texto no vacío u omitirse")
    limit = validate_limit(limit, CATALOG_DEFAULT_LIMIT, CATALOG_MAX_LIMIT)

    with open_connection() as conn:
        products, aliases = _catalog(conn)

    needle = normalize_text(query) if query else None
    matches = [
        p for p in products
        if needle is None or any(needle in normalize_text(name) for name in [p["nombre"], *aliases.get(p["id"], [])])
    ]

    return {
        "found": bool(matches),
        "source": "catalog",
        "query": query,
        "count": min(len(matches), limit),
        "has_more": len(matches) > limit,
        "products": [
            {"id": p["id"], "name": p["nombre"], "price": p["precio"], "aliases": aliases.get(p["id"], []),
             "source": "catalog"}
            for p in matches[:limit]
        ],
    }


def discussed_products(conn, client_id: int, salesperson_id: int, limit: int = CLIENT_PRODUCTS_LIMIT) -> list[dict]:
    """Productos mencionados en actividades DEL comercial con el cliente."""
    rows = conn.execute("""
        SELECT p.id, p.nombre, COUNT(DISTINCT a.id) AS activities, MAX(a.datetime_iso) AS last_date
        FROM activity_products ap
        JOIN activities a ON a.id = ap.activity_id
        JOIN products p ON p.id = ap.product_id
        WHERE a.client_id = ? AND a.salesperson_id = ?
        GROUP BY p.id
        ORDER BY activities DESC, last_date DESC, p.nombre, p.id
        LIMIT ?
    """, (client_id, salesperson_id, limit)).fetchall()
    return [
        {"id": r["id"], "name": r["nombre"], "activity_count": r["activities"],
         "last_activity_datetime": r["last_date"], "source": "activity"}
        for r in rows
    ]


def invoiced_products(conn, client_id: int, limit: int = CLIENT_PRODUCTS_LIMIT) -> list[dict]:
    """Productos facturados al cliente (global: las facturas no tienen propietario)."""
    rows = conn.execute("""
        SELECT p.id, p.nombre, SUM(il.total) AS total, SUM(il.cantidad) AS quantity,
               COUNT(DISTINCT i.id) AS invoices, MAX(i.fecha) AS last_date
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        JOIN products p ON p.id = il.product_id
        WHERE i.client_id = ?
        GROUP BY p.id
        ORDER BY total DESC, p.nombre, p.id
        LIMIT ?
    """, (client_id, limit)).fetchall()
    return [
        {"id": r["id"], "name": r["nombre"], "total_billed": r["total"] or 0, "quantity": r["quantity"],
         "invoice_count": r["invoices"], "last_invoice_date": r["last_date"], "source": "invoice"}
        for r in rows
    ]


def get_client_products(client_id: int, salesperson_id: int) -> dict:
    """Productos con evidencia real para un cliente: tratados (actividad) y facturados (factura), por separado."""
    client_id = validate_id(client_id, "client_id")

    with open_connection() as conn:
        client = conn.execute("SELECT id, razon_social FROM clients WHERE id = ?", (client_id,)).fetchone()
        if client is None:
            return {"found": False, "client_id": client_id}
        discussed = discussed_products(conn, client_id, salesperson_id)
        invoiced = invoiced_products(conn, client_id)

    return {
        "found": True,
        "client": {"id": client["id"], "name": client["razon_social"]},
        "discussed": discussed,
        "invoiced": invoiced,
    }
