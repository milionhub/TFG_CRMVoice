"""
Productos (I.8): alta, edición y baja del CATÁLOGO comercial. Es compartido
por todos los comerciales (como clientes y contactos) y la tabla `products`
sigue siendo la única fuente de verdad: nombre y PVP (precio en euros, REAL,
como siempre). CRMVoice no gestiona inventario: no hay stock ni movimientos
(la cantidad de una venta son las unidades vendidas, no existencias).

- Duplicados (bloquean): el nombre coincide con el nombre o un alias de otro
  producto, sin tildes, mayúsculas ni puntuación ("Ratón Faro" = "raton faro").
- Baja segura: solo de un producto que nada usa. Si aparece en actividades,
  ventas o facturas, borrarlo cambiaría el histórico: Conflict (409) con el
  detalle. Sus alias se borran en cascada.
"""
import sqlite3
from datetime import datetime

import db
from schemas.crm import ProductIn
from schemas.issues import Candidate, Issue, issue
from services.entity_resolver import normalize_text
from services.writes import Conflict, NotFound, current_time, exists, raise_if_blocking, transaction

PRODUCT_NOT_FOUND = "Producto no encontrado"


def product_out(conn: sqlite3.Connection, product_id: int) -> dict:
    row = conn.execute("SELECT id, nombre, precio FROM products WHERE id = ?", (product_id,)).fetchone()
    if row is None:
        raise NotFound(PRODUCT_NOT_FOUND)
    return {"id": row["id"], "name": row["nombre"], "price": row["precio"]}


def product_issues(conn: sqlite3.Connection, name: str, *, exclude_id: int | None = None) -> list[Issue]:
    """Validación de negocio del nombre: no puede repetir el nombre o un alias de otro producto."""
    key = normalize_text(name)
    rows = conn.execute("""
        SELECT p.id, p.nombre AS name, p.nombre AS term FROM products p WHERE p.id IS NOT ?
        UNION ALL
        SELECT p.id, p.nombre, a.alias FROM product_aliases a JOIN products p ON p.id = a.product_id
        WHERE p.id IS NOT ?
        ORDER BY 1
    """, (exclude_id, exclude_id)).fetchall()
    for row in rows:
        if key and normalize_text(row["term"]) == key:
            return [issue("duplicate", "name", f"Ya existe el producto «{row['name']}».", existing_id=row["id"],
                          candidates=[Candidate(id=row["id"], label=row["name"])])]
    return []


def create_product(data: ProductIn, salesperson_id: int, *, conn: sqlite3.Connection | None = None,
                   now: datetime | None = None) -> dict:
    with transaction(conn) as c:
        raise_if_blocking(product_issues(c, data.name))
        product_id = c.execute("INSERT INTO products (nombre, precio) VALUES (?, ?)",
                               (data.name, data.price_cents / 100)).lastrowid
        return product_out(c, product_id)


def update_product(product_id: int, data: ProductIn, salesperson_id: int, *,
                   conn: sqlite3.Connection | None = None, now: datetime | None = None) -> dict:
    """Sustitución completa de nombre y PVP. Las actividades y ventas siguen apuntando al mismo id."""
    with transaction(conn) as c:
        if not exists(c, "products", product_id):
            raise NotFound(PRODUCT_NOT_FOUND)
        raise_if_blocking(product_issues(c, data.name, exclude_id=product_id))
        c.execute("UPDATE products SET nombre = ?, precio = ? WHERE id = ?",
                  (data.name, data.price_cents / 100, product_id))
        return product_out(c, product_id)


def product_usage(conn: sqlite3.Connection, product_id: int) -> dict:
    def count(sql):
        return conn.execute(sql, (product_id,)).fetchone()[0]
    return {"activities": count("SELECT COUNT(*) FROM activity_products WHERE product_id = ?"),
            "sales": count("SELECT COUNT(*) FROM sales WHERE product_id = ?"),
            "invoices": count("SELECT COUNT(*) FROM invoice_lines WHERE product_id = ?")}


def delete_product(product_id: int, salesperson_id: int, *, conn: sqlite3.Connection | None = None) -> None:
    with transaction(conn) as c:
        if not exists(c, "products", product_id):
            raise NotFound(PRODUCT_NOT_FOUND)
        usage = product_usage(c, product_id)
        if any(usage.values()):
            used = [f"{n} {label}" for label, n in (("actividades", usage["activities"]), ("ventas", usage["sales"]),
                                                    ("líneas de factura", usage["invoices"])) if n]
            raise Conflict("product_in_use", "No se puede eliminar: el producto aparece en " + ", ".join(used)
                           + ". Así se conserva el histórico.", extra={"usage": usage})
        c.execute("DELETE FROM products WHERE id = ?", (product_id,))   # sus alias se borran en cascada


def get_product(product_id: int) -> dict:
    with db.connection() as c:            # solo lectura: sin el bloqueo de escritura
        return product_out(c, product_id)


__all__ = ["product_out", "product_issues", "create_product", "update_product", "product_usage",
           "delete_product", "get_product", "current_time"]
