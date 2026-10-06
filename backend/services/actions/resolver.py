"""
Resolvedor determinista del Action Engine (H.2).

    Interpretation (menciones) -> campos del borrador con ids -> issues

- Los ids salen SOLO de aquí, con la lógica ya probada en F/G:
  clientes y contactos con crm_tools.entities.find_entities (exact, fuzzy,
  partial, inherited, ambiguous, conflict); productos con
  crm_tools.products.resolve_product (+ entity_resolver.resolve_products
  como respaldo fuzzy); tipos de actividad por su nombre exacto.
- Nunca elige ante la ambigüedad ni corrige un conflicto en silencio: lo
  convierte en un issue bloqueante con candidatos emitidos por el servidor.
  Un parecido (fuzzy/partial) o un cliente deducido del contacto se resuelve,
  pero con un aviso visible ("Has dicho «X»: Y"). Ninguna confianza decide.
- issues_for() calcula SIEMPRE los issues a partir de los campos y de la BD
  actual, reutilizando la validación de los servicios de escritura: se usa al
  crear el borrador, al editarlo y otra vez al confirmarlo.
- write_input() convierte un borrador sin issues bloqueantes en la MISMA
  entrada tipada que usan los formularios (ActivityIn, ClientIn...).
"""
import sqlite3
from datetime import datetime

from pydantic import BaseModel, ValidationError

from core.formats import FormatError, capitalize_first, iso_now, parse_date, parse_money_cents, parse_time
from schemas.actions import (DRAFT_MODELS, EDIT_MODELS, ActivityDraft, ClientDraft, ContactDraft, Interpretation,
                             ResolvedRef, SaleDraft, SaleLineDraft)
from schemas.crm import ActivityIn, ClientIn, ContactIn, SaleCreate, SaleLineIn, cents_to_text
from schemas.issues import Candidate, Issue, has_blocking, issue
from services.actions.types import MAX_DATE_DISTANCE_DAYS, MAX_PRODUCTS, MAX_SALE_LINES
from services.crm_tools._common import open_connection
from services.crm_tools.entities import find_entities
from services.crm_tools.products import resolve_product
from services.entity_resolver import normalize_text, resolve_products
from services.writes import ValidationFailed, validation_issues
from services.writes.activities import activity_issues
from services.writes.clients import client_issues
from services.writes.contacts import contact_issues
from services.writes.sales import sale_issues

MAX_NAME = 120
RESOLVED_CLIENT = ("exact", "fuzzy", "partial", "inherited")
RESOLVED_CONTACT = ("exact", "fuzzy", "partial")


def _clean(value: str | None, limit: int = MAX_NAME) -> str | None:
    if value is None:
        return None
    value = " ".join(str(value).split())
    return value[:limit] or None


# =====================================================================
# Entidades: menciones -> ResolvedRef
# =====================================================================

def resolve_client_contact(client_name: str | None, contact_name: str | None, salesperson_id: int
                           ) -> tuple[ResolvedRef | None, ResolvedRef | None]:
    """Cliente y contacto con la semántica de find_entities (la del chat)."""
    client_name, contact_name = _clean(client_name), _clean(contact_name)
    if not client_name and not contact_name:
        return None, None
    found = find_entities(None, salesperson_id, client_name=client_name, contact_name=contact_name)
    c, k = found["client"], found["contact"]

    client = None
    if c["id"] and c["status"] in RESOLVED_CLIENT:
        client = ResolvedRef(id=c["id"], label=c["name"], match=c["status"],
                             said=None if c["status"] == "inherited" else client_name)
    elif c["status"] == "ambiguous" and client_name:
        client = ResolvedRef(said=client_name, problem="ambiguous",
                             candidates=[Candidate(id=x["id"], label=x["name"]) for x in c["candidates"]])
    elif c["status"] == "conflict" and client_name:
        # Se dijo un cliente que no existe y el contacto es de otro: se ofrece ese otro, sin elegirlo
        owner = [Candidate(id=k["client_id"], label=_client_label(k["client_id"]))] if k["client_id"] else []
        client = ResolvedRef(said=client_name, problem="conflict", candidates=owner)
    elif client_name:
        client = ResolvedRef(said=client_name, problem="not_found")

    contact = None
    if k["id"] and k["status"] in RESOLVED_CONTACT:
        contact = ResolvedRef(id=k["id"], label=k["name"], said=contact_name, match=k["status"])
    elif k["status"] in ("ambiguous", "conflict") and contact_name:
        contact = ResolvedRef(said=contact_name, problem=k["status"], candidates=[
            Candidate(id=x["id"], label=f'{x["name"]} ({x["client_name"]})') for x in k["candidates"]])
    elif contact_name:
        contact = ResolvedRef(said=contact_name, problem="not_found")
    return client, contact


def _client_label(client_id: int) -> str:
    with open_connection() as conn:
        row = conn.execute("SELECT razon_social FROM clients WHERE id = ?", (client_id,)).fetchone()
    return row["razon_social"] if row else f"Cliente {client_id}"


def resolve_product_ref(conn: sqlite3.Connection, name: str) -> ResolvedRef:
    said = _clean(name)
    if not said:
        return ResolvedRef(said=name, problem="not_found")
    result = resolve_product(conn, said)
    if result["status"] == "resolved":
        product = result["product"]
        exact = normalize_text(said) in _product_names(conn, product["id"])
        return ResolvedRef(id=product["id"], label=product["name"], said=said, match="exact" if exact else "partial")
    if result["status"] == "ambiguous":
        return ResolvedRef(said=said, problem="ambiguous", candidates=_product_candidates(conn, result["candidates"]))
    fuzzy = resolve_products(said)   # respaldo: parecido por frases del catálogo (umbral de la Fase F)
    if len(fuzzy) == 1:
        product_id = fuzzy[0]["product_id"]
        label = conn.execute("SELECT nombre FROM products WHERE id = ?", (product_id,)).fetchone()["nombre"]
        return ResolvedRef(id=product_id, label=label, said=said, match="fuzzy")
    if len(fuzzy) > 1:
        return ResolvedRef(said=said, problem="ambiguous", candidates=[
            Candidate(id=f["product_id"], label=_name_of(conn, "products", "nombre", f["product_id"])) for f in fuzzy])
    return ResolvedRef(said=said, problem="not_found")


def _product_names(conn, product_id: int) -> set[str]:
    names = [conn.execute("SELECT nombre FROM products WHERE id = ?", (product_id,)).fetchone()["nombre"]]
    names += [r["alias"] for r in conn.execute("SELECT alias FROM product_aliases WHERE product_id = ?",
                                               (product_id,)).fetchall()]
    return {normalize_text(n) for n in names}


def _product_candidates(conn, names: list[str]) -> list[Candidate]:
    rows = [conn.execute("SELECT id, nombre FROM products WHERE nombre = ?", (n,)).fetchone() for n in names]
    return [Candidate(id=r["id"], label=r["nombre"]) for r in rows if r]


def _name_of(conn, table: str, column: str, row_id: int) -> str:
    row = conn.execute(f"SELECT {column} FROM {table} WHERE id = ?", (row_id,)).fetchone()
    return row[column] if row else str(row_id)


def ref_by_id(conn: sqlite3.Connection, table: str, column: str, row_id: int) -> ResolvedRef:
    """Elección explícita del usuario (edición): se comprueba que exista; las relaciones, en issues_for."""
    row = conn.execute(f"SELECT id, {column} AS label FROM {table} WHERE id = ?", (row_id,)).fetchone()
    if row is None:
        return ResolvedRef(problem="not_found")
    return ResolvedRef(id=row["id"], label=row["label"], match="user_selected")


def _activity_type_ref(conn, name: str | None) -> ResolvedRef | None:
    if not name:
        return None
    row = conn.execute("SELECT id, accion FROM activity_types WHERE accion = ?", (name,)).fetchone()
    if row is None:
        return ResolvedRef(said=name, problem="not_found")
    return ResolvedRef(id=row["id"], label=row["accion"], said=name, match="exact")


def _group_ref(conn, name: str | None) -> ResolvedRef | None:
    name = _clean(name, 80)
    if not name:
        return None
    for row in conn.execute("SELECT id, name FROM client_groups").fetchall():
        if normalize_text(row["name"]) == normalize_text(name):
            return ResolvedRef(id=row["id"], label=row["name"], said=name, match="exact")
    return ResolvedRef(said=name, problem="not_found")


# =====================================================================
# Interpretation -> borrador
# =====================================================================

def resolve(interpretation: Interpretation, source_text: str, salesperson_id: int, now: datetime
            ) -> tuple[str, BaseModel]:
    """(action_type, campos). Una acción no soportada no crea borrador: ValidationFailed "unsupported"."""
    kind = interpretation.action_type
    if kind == "unsupported":
        reason = _clean(interpretation.unsupported_reason, 300) or "Esa petición no es una acción que pueda preparar."
        message = (f"{reason} Puedo preparar: una actividad, un cliente, un contacto o una venta. "
                   "Para consultar datos usa el Chat IA; para cambiar o completar algo, la pantalla correspondiente.")
        raise ValidationFailed([issue("unsupported", "action", message)], message)
    with open_connection() as conn:
        if kind == "create_activity":
            return kind, _activity_draft(conn, interpretation, source_text, salesperson_id, now)
        if kind == "create_client":
            return kind, _client_draft(conn, interpretation)
        if kind == "create_contact":
            return kind, _contact_draft(interpretation, salesperson_id)
        return kind, _sale_draft(conn, interpretation, salesperson_id, now)


def _activity_draft(conn, it: Interpretation, source_text: str, salesperson_id: int, now: datetime) -> ActivityDraft:
    client, contact = resolve_client_contact(it.client_name, it.contact_name, salesperson_id)
    day = _clean(it.date, 20)
    hour = _normalize_time(it.time)
    status = it.status
    defaulted = False
    today = now.date().isoformat()
    if status == "completed":
        day = day or today
        if hour is None and day == today:
            hour, defaulted = now.strftime("%H:%M"), True     # visible en el borrador
    elif status is None and day and hour and _valid_day(day):
        status = "pending" if f"{day}T{hour}:00" > iso_now(now) else "completed"
    elif status is None and day and _valid_day(day) and day > today:
        status = "pending"
    return ActivityDraft(
        client=client, contact=contact, activity_type=_activity_type_ref(conn, it.activity_type),
        date=day, time=hour, time_defaulted=defaulted, status=status,
        products=[resolve_product_ref(conn, p) for p in it.products[:MAX_PRODUCTS + 1]],
        comment=_clean(it.comment, 2000) or _clean(source_text, 2000),
    )


def _client_draft(conn, it: Interpretation) -> ClientDraft:
    new = it.new_client
    return ClientDraft(name=_clean(new.name if new and new.name else it.client_name),
                       alias=_clean(new.alias, 60) if new else None,
                       city=_clean(new.city, 80) if new else None,
                       province=_clean(new.province, 80) if new else None,
                       group=_group_ref(conn, new.group_name) if new else None)


def _contact_draft(it: Interpretation, salesperson_id: int) -> ContactDraft:
    new = it.new_contact
    client, _ = resolve_client_contact(it.client_name, None, salesperson_id)  # el contacto es NUEVO: no se busca
    return ContactDraft(client=client, name=_clean(new.name if new and new.name else it.contact_name, 80),
                        role=capitalize_first(_clean(new.role, 80)) if new else None,
                        email=_clean(new.email, 120) if new else None,
                        phone=_clean(new.phone, 30) if new else None)


def _sale_draft(conn, it: Interpretation, salesperson_id: int, now: datetime) -> SaleDraft:
    client, contact = resolve_client_contact(it.client_name, it.contact_name, salesperson_id)
    lines = [_sale_line(conn, line.product_name, line.concept, line.quantity, line.amount, line.amount_is_unit_price)
             for line in it.sale_lines[:MAX_SALE_LINES + 1]]
    return SaleDraft(client=client, contact=contact, sale_date=_clean(it.sale_date, 20) or now.date().isoformat(),
                     lines=lines)


def _sale_line(conn, product_name, concept, quantity, amount, is_unit: bool = False) -> SaleLineDraft:
    product = resolve_product_ref(conn, product_name) if _clean(product_name) else None
    line = SaleLineDraft(product=product, concept=capitalize_first(_clean(concept, 200)), quantity=quantity,
                         amount_said=None if amount is None else _clean(str(amount), 40))
    if amount is not None:
        try:
            cents = parse_money_cents(amount)
            if is_unit:
                if not quantity:
                    raise FormatError("Se ha dicho un precio por unidad pero no la cantidad.")
                cents *= quantity
            line.amount_cents = cents
        except FormatError as error:
            line.amount_error = str(error)
    if product and product.id and quantity:
        price = conn.execute("SELECT precio FROM products WHERE id = ?", (product.id,)).fetchone()["precio"]
        if price is not None:
            line.reference_total_cents = int(round(price * 100)) * quantity
    return line


def _normalize_time(value: str | None) -> str | None:
    if not value:
        return None
    try:
        return parse_time(value)
    except FormatError:
        return _clean(value, 20)     # se guarda tal cual: issues_for lo marcará como no válido


def _valid_day(value: str) -> bool:
    try:
        parse_date(value)
        return True
    except FormatError:
        return False


# =====================================================================
# Ediciones (PATCH): tipadas por acción, nunca un merge de JSON arbitrario
# =====================================================================

def apply_edits(action_type: str, fields: BaseModel, raw_edits: dict, salesperson_id: int,
                now: datetime) -> BaseModel:
    try:
        edits = EDIT_MODELS[action_type].model_validate(raw_edits)
    except ValidationError as error:
        issues = validation_issues(error, prefix="edits")
        raise ValidationFailed(issues, issues[0].message) from None
    changed = edits.model_fields_set
    if not changed:
        raise ValidationFailed([issue("missing", "edits", "No hay cambios.")], "No hay cambios.")
    updated = fields.model_copy(deep=True)
    with open_connection() as conn:
        if action_type == "create_activity":
            _edit_activity(conn, updated, edits, changed, salesperson_id)
        elif action_type == "create_client":
            _edit_client(conn, updated, edits, changed)
        elif action_type == "create_contact":
            _edit_contact(conn, updated, edits, changed, salesperson_id)
        else:
            _edit_sale(conn, updated, edits, changed, salesperson_id)
    return updated


def _edit_client_contact(conn, target, edits, changed, salesperson_id, *, with_contact: bool):
    if "client_id" in changed:
        target.client = ref_by_id(conn, "clients", "razon_social", edits.client_id) if edits.client_id else None
    elif "client_name" in changed:
        target.client, _ = resolve_client_contact(edits.client_name, None, salesperson_id)
    if not with_contact:
        return
    if "contact_id" in changed:
        target.contact = ref_by_id(conn, "contacts", "nombre", edits.contact_id) if edits.contact_id else None
    elif "contact_name" in changed:
        if edits.contact_name:
            client_label = target.client.label if target.client and target.client.id else None
            client, target.contact = resolve_client_contact(client_label, edits.contact_name, salesperson_id)
            if target.client is None and client is not None and client.match == "inherited":
                target.client = client
        else:
            target.contact = None


def _edit_activity(conn, f: ActivityDraft, e, changed, salesperson_id):
    _edit_client_contact(conn, f, e, changed, salesperson_id, with_contact=True)
    if "activity_type_id" in changed:
        f.activity_type = ref_by_id(conn, "activity_types", "accion", e.activity_type_id) if e.activity_type_id else None
    if "date" in changed:
        f.date = _clean(e.date, 20)
    if "time" in changed:
        f.time, f.time_defaulted = _normalize_time(e.time), False
    if "status" in changed:
        f.status = e.status
    if "product_ids" in changed:
        f.products = [ref_by_id(conn, "products", "nombre", pid) for pid in (e.product_ids or [])]
    elif "product_names" in changed:
        f.products = [resolve_product_ref(conn, name) for name in (e.product_names or [])]
    if "comment" in changed:
        f.comment = _clean(e.comment, 2000)


def _edit_client(conn, f: ClientDraft, e, changed):
    for name in ("name", "alias", "city", "province"):
        if name in changed:
            setattr(f, name, _clean(getattr(e, name)))
    if "group_id" in changed:
        f.group = ref_by_id(conn, "client_groups", "name", e.group_id) if e.group_id else None


def _edit_contact(conn, f: ContactDraft, e, changed, salesperson_id):
    _edit_client_contact(conn, f, e, changed, salesperson_id, with_contact=False)
    for name in ("name", "role", "email", "phone"):
        if name in changed:
            setattr(f, name, _clean(getattr(e, name)))
    if "role" in changed:
        f.role = capitalize_first(f.role)        # misma política que el formulario (H4-03)


def _edit_sale(conn, f: SaleDraft, e, changed, salesperson_id):
    _edit_client_contact(conn, f, e, changed, salesperson_id, with_contact=True)
    if "sale_date" in changed:
        f.sale_date = _clean(e.sale_date, 20)
    if "notes" in changed:
        f.notes = _clean(e.notes, 500)
    if "lines" in changed and e.lines is not None:
        lines = []
        for edit in e.lines:
            line = _sale_line(conn, edit.product_name, edit.concept, edit.quantity, edit.amount)
            if edit.product_id is not None:
                line.product = ref_by_id(conn, "products", "nombre", edit.product_id)
                line.reference_total_cents = None
            lines.append(line)
        f.lines = lines


# =====================================================================
# Issues: SIEMPRE recalculados desde los campos y la BD actual
# =====================================================================

_LABELS = {"client": ("el cliente", "clientes"), "contact": ("el contacto", "contactos"),
           "activity_type": ("el tipo de actividad", "tipos de actividad"), "group": ("el grupo", "grupos"),
           "product": ("el producto", "productos")}


def _ref_issues(ref: ResolvedRef | None, field: str, kind: str, *, required: bool,
                not_found_blocking: bool = True) -> list[Issue]:
    label, plural = _LABELS[kind]
    if ref is None or (ref.id is None and ref.problem is None and not ref.said):
        return [issue("missing", field, f"Falta {label}.")] if required else []
    if ref.problem == "ambiguous":
        return [issue("ambiguous", field, f"Hay varios {plural} que encajan con «{ref.said}»: elige uno.",
                      candidates=ref.candidates)]
    if ref.problem == "conflict":
        if kind == "contact":
            message = f"«{ref.said}» no es un contacto de ese cliente."
        else:
            message = f"No existe el cliente «{ref.said}» y el contacto que has dicho es de otro cliente."
        return [issue("conflict", field, message, candidates=ref.candidates)]
    if ref.problem == "not_found" or ref.id is None:
        said = f" «{ref.said}»" if ref.said else ""
        return [issue("not_found", field, f"No encuentro {label}{said} en el CRM.", blocking=not_found_blocking)]
    if ref.match in ("fuzzy", "partial"):
        return [issue("fuzzy_match", field, f"Has dicho «{ref.said}»: {ref.label}.", blocking=False)]
    if ref.match == "inherited":
        return [issue("fuzzy_match", field, f"Cliente deducido del contacto: {ref.label}.", blocking=False)]
    return []


def _date_issue(value: str | None, field: str, now: datetime) -> Issue | None:
    try:
        day = parse_date(value)
    except FormatError as error:
        return issue("invalid", field, str(error))
    if abs((day - now.date()).days) > MAX_DATE_DISTANCE_DAYS:
        return issue("invalid", field, "La fecha está a más de dos años de hoy: revísala.")
    return None


def issues_for(action_type: str, fields: BaseModel, salesperson_id: int, now: datetime,
               conn: sqlite3.Connection) -> list[Issue]:
    if action_type == "create_activity":
        issues = _activity_issues(fields, now)
    elif action_type == "create_client":
        issues = [] if fields.name else [issue("missing", "name", "Falta el nombre del cliente.")]
        issues += _ref_issues(fields.group, "group", "group", required=False, not_found_blocking=False)
    elif action_type == "create_contact":
        issues = _ref_issues(fields.client, "client", "client", required=True)
        if not fields.name:
            issues.append(issue("missing", "name", "Falta el nombre del contacto."))
    else:
        issues = _sale_issues(fields, now)
    if has_blocking(issues):
        return issues
    # Sin problemas de resolución: la validación de negocio es la de los servicios de escritura
    try:
        data, _ = write_input(action_type, fields, now)
    except ValidationFailed as error:
        return issues + error.issues
    if action_type == "create_activity":
        return issues + activity_issues(conn, data, salesperson_id, now)
    if action_type == "create_client":
        return issues + client_issues(conn, data)
    if action_type == "create_contact":
        return issues + contact_issues(conn, data, data.client_id)
    return issues + sale_issues(conn, data, now)


def _activity_issues(f: ActivityDraft, now: datetime) -> list[Issue]:
    issues = _ref_issues(f.client, "client", "client", required=True)
    issues += _ref_issues(f.contact, "contact", "contact", required=False)
    issues += _ref_issues(f.activity_type, "activity_type", "activity_type", required=True)
    if len(f.products) > MAX_PRODUCTS:
        issues.append(issue("invalid", "products", f"Como mucho {MAX_PRODUCTS} productos por actividad."))
    for index, product in enumerate(f.products[:MAX_PRODUCTS]):
        issues += _ref_issues(product, f"products[{index}]", "product", required=True)
    if f.date is None:
        issues.append(issue("missing", "date", "Falta el día de la actividad."))
    elif (problem := _date_issue(f.date, "date", now)) is not None:
        issues.append(problem)
    if f.time is None:
        issues.append(issue("missing", "time", "Falta la hora de la actividad."))
    else:
        try:
            parse_time(f.time)
        except FormatError as error:
            issues.append(issue("invalid", "time", str(error)))
    if f.time_defaulted:
        issues.append(issue("missing", "time", f"No has dicho la hora: se guardará a las {f.time}.", blocking=False))
    if f.status is None:
        issues.append(issue("missing", "status", "Indica si la actividad está pendiente o ya hecha."))
    return issues


def _sale_issues(f: SaleDraft, now: datetime) -> list[Issue]:
    issues = _ref_issues(f.client, "client", "client", required=True)
    issues += _ref_issues(f.contact, "contact", "contact", required=False)
    if f.sale_date is None:
        issues.append(issue("missing", "sale_date", "Falta la fecha de la venta."))
    elif (problem := _date_issue(f.sale_date, "sale_date", now)) is not None:
        issues.append(problem)
    if not f.lines:
        issues.append(issue("missing", "lines", "Indica al menos un producto o concepto con su importe."))
    if len(f.lines) > MAX_SALE_LINES:
        issues.append(issue("invalid", "lines", f"Como mucho {MAX_SALE_LINES} líneas por venta."))
    for index, line in enumerate(f.lines[:MAX_SALE_LINES]):
        prefix = f"lines[{index}]"
        if line.product is not None:
            issues += _ref_issues(line.product, f"{prefix}.product", "product", required=True)
        elif not line.concept:
            issues.append(issue("missing", f"{prefix}.product", "Indica el producto o un concepto."))
        if line.amount_error:
            issues.append(issue("invalid", f"{prefix}.amount", line.amount_error))
        elif line.amount_cents is None:
            issues.append(issue("missing", f"{prefix}.amount", "Falta el importe."))
    return issues


# =====================================================================
# Borrador -> entrada tipada de los servicios de escritura
# =====================================================================

def write_input(action_type: str, fields: BaseModel, now: datetime) -> tuple[BaseModel, dict]:
    """(entrada tipada, provenance). Lanza ValidationFailed si los campos no forman una entrada válida."""
    try:
        if action_type == "create_activity":
            f: ActivityDraft = fields
            data = ActivityIn(
                client_id=f.client.id, contact_id=f.contact.id if f.contact else None,
                activity_type_id=f.activity_type.id, datetime=f"{f.date}T{f.time}:00", status=f.status,
                product_ids=[p.id for p in f.products], comment=f.comment)
            provenance = {"cliente_raw": f.client.said, "contacto_raw": f.contact.said if f.contact else None,
                          "accion_raw": f.activity_type.label, "resolution_status": "confirmed",
                          "product_raw": {p.id: p.said for p in f.products}}
            return data, provenance
        if action_type == "create_client":
            f: ClientDraft = fields
            return ClientIn(name=f.name, alias=f.alias, city=f.city, province=f.province,
                            group_id=f.group.id if f.group else None), {}
        if action_type == "create_contact":
            f: ContactDraft = fields
            return ContactIn(client_id=f.client.id, name=f.name, role=f.role, email=f.email, phone=f.phone), {}
        f: SaleDraft = fields
        lines = [SaleLineIn(product_id=line.product.id if line.product else None, concept=line.concept,
                            quantity=line.quantity, amount=cents_to_text(line.amount_cents)) for line in f.lines]
        return SaleCreate(client_id=f.client.id, contact_id=f.contact.id if f.contact else None,
                          sale_date=f.sale_date, notes=f.notes, lines=lines), {}
    except ValidationError as error:
        issues = validation_issues(error)
        raise ValidationFailed(issues, issues[0].message) from None


def load_fields(action_type: str, payload_json: str) -> BaseModel:
    return DRAFT_MODELS[action_type].model_validate_json(payload_json)


__all__ = ["resolve", "apply_edits", "issues_for", "write_input", "load_fields"]
