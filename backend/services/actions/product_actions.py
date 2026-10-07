"""
Acciones del catálogo de productos en el Action Engine (I.8): create_product
y update_product. CRMVoice no gestiona inventario: no hay acciones de stock.

Mismo ciclo que las demás (y por el mismo código: drafts, executor):
interpretación (LLM, solo menciones) -> borrador con ids del resolvedor
determinista -> revisión -> confirmación explícita -> escritura con
services/writes/products. Interpretar una frase NUNCA modifica el catálogo.

Cada acción es un `ProductAction` (draft, edit, issues, business_issues,
write_input, execute); resolver y executor los despachan con
PRODUCT_ACTIONS, sin cadenas de if/else por tipo.

- create_product: entidad NUEVA: se normalizan las mayúsculas del nombre
  (core.formats.name_case) pero nunca se cambia por un producto parecido;
  un duplicado (mismo nombre o alias) bloquea; el PVP es obligatorio.
- update_product: producto EXISTENTE (resolve_product_ref: exacto, parcial o
  fuzzy seguro; ambiguo -> candidatos; nunca inventa). Solo cambia lo dicho
  (PVP y/o nombre); al confirmar, lo que no cambia se toma de la BD actual.
"""
import sqlite3
from dataclasses import dataclass
from datetime import datetime
from typing import Callable

from pydantic import BaseModel

from core.formats import FormatError, name_case, parse_money_cents
from schemas.actions import Interpretation, ProductDraft, ProductUpdateDraft, ResolvedRef
from schemas.crm import ProductIn, cents_to_text
from schemas.issues import Issue, issue
from services.actions import resolver as r
from services.writes import products as product_writes


@dataclass(frozen=True)
class ProductAction:
    draft: Callable[[sqlite3.Connection, Interpretation, str, datetime], BaseModel]
    edit: Callable[[sqlite3.Connection, BaseModel, BaseModel, set], None]
    issues: Callable[[BaseModel], list[Issue]]                                           # forma y resolución
    business_issues: Callable[[sqlite3.Connection, BaseModel, BaseModel], list[Issue]]   # con la BD actual
    write_input: Callable[[BaseModel], BaseModel]
    execute: Callable[[BaseModel, BaseModel, int, sqlite3.Connection, datetime], dict]


# =====================================================================
# Comunes
# =====================================================================

def _price(value) -> tuple[int | None, str | None, str | None]:
    """(céntimos, lo dicho, error) con las reglas de importes de siempre (parse_money_cents)."""
    if value is None:
        return None, None, None
    said = r._clean(str(value), 40)
    try:
        return parse_money_cents(value), said, None
    except FormatError as error:
        return None, said, str(error).replace("importe", "precio").replace("Importe", "Precio")


def _row(conn, product_id: int | None):
    if product_id is None:
        return None
    return conn.execute("SELECT id, nombre, precio FROM products WHERE id = ?", (product_id,)).fetchone()


def _cents(price) -> int | None:
    return None if price is None else int(round(price * 100))


def _existing_product(conn, it: Interpretation, source_text: str) -> ResolvedRef | None:
    """Producto EXISTENTE: el dicho (resolve_product_ref) o, si el intérprete no lo dio, uno solo del texto."""
    said = it.product.name if it.product else None
    if r._clean(said):
        return r.resolve_product_ref(conn, said)
    found = r.merge_text_products(conn, [], source_text)
    return found[0] if len(found) == 1 else None


# =====================================================================
# create_product
# =====================================================================

def _create_draft(conn, it: Interpretation, source_text: str, now: datetime) -> ProductDraft:
    mention = it.product
    cents, said, error = _price(mention.price if mention else None)
    return ProductDraft(name=name_case(r._clean(mention.name if mention else None, 100)),
                        price_cents=cents, price_said=said, price_error=error)


def _create_edit(conn, f: ProductDraft, e, changed) -> None:
    if "name" in changed:
        f.name = r._clean(e.name, 100)                 # lo que escribe el usuario se respeta tal cual
    if "price" in changed:
        f.price_cents, f.price_said, f.price_error = _price(e.price)


def _create_issues(f: ProductDraft) -> list[Issue]:
    issues = [] if f.name else [issue("missing", "name", "Falta el nombre del producto.")]
    if f.price_error:
        issues.append(issue("invalid", "price", f.price_error))
    elif f.price_cents is None:
        issues.append(issue("missing", "price", "Falta el PVP del producto."))
    return issues


def _create_input(f: ProductDraft) -> ProductIn:
    return ProductIn(name=f.name, price=cents_to_text(f.price_cents))


def _create_business(conn, data: ProductIn, f) -> list[Issue]:
    return product_writes.product_issues(conn, data.name)


def _create_execute(data: ProductIn, f, salesperson_id: int, conn, now) -> dict:
    created = product_writes.create_product(data, salesperson_id, conn=conn, now=now)
    return {"entity": "product", "ids": [created["id"]], "data": created}


# =====================================================================
# update_product
# =====================================================================

def _snapshot(conn, f: ProductUpdateDraft) -> None:
    """Valores actuales del producto elegido (para mostrar «antes → después»)."""
    row = _row(conn, f.product.id if f.product else None)
    f.current_name = row["nombre"] if row else None
    f.current_price_cents = _cents(row["precio"]) if row else None


def _update_draft(conn, it: Interpretation, source_text: str, now: datetime) -> ProductUpdateDraft:
    mention = it.product
    cents, said, error = _price(mention.price if mention else None)
    f = ProductUpdateDraft(product=_existing_product(conn, it, source_text),
                           name=name_case(r._clean(mention.new_name if mention else None, 100)),
                           price_cents=cents, price_said=said, price_error=error)
    _snapshot(conn, f)
    return f


def _update_edit(conn, f: ProductUpdateDraft, e, changed) -> None:
    if "product_id" in changed:
        f.product = r.ref_by_id(conn, "products", "nombre", e.product_id) if e.product_id else None
    elif "product_name" in changed:
        f.product = r.resolve_product_ref(conn, e.product_name) if r._clean(e.product_name) else None
    if "name" in changed:
        f.name = r._clean(e.name, 100)
    if "price" in changed:
        f.price_cents, f.price_said, f.price_error = _price(e.price)
    _snapshot(conn, f)


def _update_issues(f: ProductUpdateDraft) -> list[Issue]:
    issues = r._ref_issues(f.product, "product", "product", required=True)
    if f.price_error:
        issues.append(issue("invalid", "price", f.price_error))
    if f.name is None and f.price_cents is None and not f.price_error:
        issues.append(issue("missing", "changes", "Indica qué cambiar del producto: el PVP o el nombre."))
    return issues


def _merged(f: ProductUpdateDraft, row) -> ProductIn:
    """Lo que quedará guardado: los cambios del borrador sobre los valores de `row`."""
    price = f.price_cents if f.price_cents is not None else _cents(row["precio"] if row else None)
    return ProductIn(name=f.name or (row["nombre"] if row else ""),
                     price=cents_to_text(price) if price else "0")


def _update_input(f: ProductUpdateDraft) -> ProductIn:
    return _merged(f, {"nombre": f.current_name, "precio": None if f.current_price_cents is None
                       else f.current_price_cents / 100})


def _update_business(conn, data: ProductIn, f: ProductUpdateDraft) -> list[Issue]:
    if _row(conn, f.product.id) is None:
        return [issue("not_found", "product", "El producto ya no existe.")]
    return product_writes.product_issues(conn, f.name, exclude_id=f.product.id) if f.name else []


def _update_execute(data, f: ProductUpdateDraft, salesperson_id: int, conn, now) -> dict:
    # Lo que no cambia se toma de la BD en ESTA transacción (no de lo que se vio al revisar)
    update = _merged(f, _row(conn, f.product.id))
    updated = product_writes.update_product(f.product.id, update, salesperson_id, conn=conn, now=now)
    return {"entity": "product", "ids": [updated["id"]], "data": updated}


PRODUCT_ACTIONS: dict[str, ProductAction] = {
    "create_product": ProductAction(_create_draft, _create_edit, _create_issues, _create_business,
                                    _create_input, _create_execute),
    "update_product": ProductAction(_update_draft, _update_edit, _update_issues, _update_business,
                                    _update_input, _update_execute),
}

__all__ = ["PRODUCT_ACTIONS", "ProductAction"]
