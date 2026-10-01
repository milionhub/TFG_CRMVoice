"""
Registro explícito de las herramientas que el modelo del chat puede pedir (G.3).

Cada entrada une:
  nombre público → modelo Pydantic de argumentos (extra prohibido, estricto)
  → función de confianza (crm_tools de G.2) → recorte del resultado
  → foco (qué cliente/contacto fija en el estado de la conversación).

Frontera de seguridad (código, no prompt):
- solo existen las herramientas de REGISTRY (búsqueda en un dict, nunca por nombre dinámico);
- salesperson_id y now los inyecta el backend: no forman parte de ningún modelo de argumentos;
- un client_id/contact_id solo se acepta si el backend ya lo conoce en esta
  petición (estado activo o resultado de una herramienta). Los candidatos de
  una resolución ambigua NO cuentan: hay que resolver el nombre;
- todas las herramientas son de solo lectura (crm_tools usa PRAGMA query_only).
"""
import json
import logging
from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable, Literal

import openai
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

from services import crm_tools
from services.crm_tools import ToolArgumentError
from services.openai_client import AIServiceError

logger = logging.getLogger("crmvoice")

MAX_RESULT_CHARS = 8_000
COMMENT_CHARS = 300
LIST_COMMENT_CHARS = 200          # en listas, más margen bajo el tope de 8k por resultado
EMBEDDING_TIMEOUT_S = 6.0
MIN_EMBEDDING_TIMEOUT_S = 1.0
LIST_DEFAULT_LIMIT = 10


# =====================================================================
# Contexto de ejecución y resultado
# =====================================================================

@dataclass
class ToolContext:
    """Datos de confianza de la petición: nunca vienen del modelo."""
    salesperson_id: int
    now: datetime
    remaining: Callable[[], float]                    # segundos que quedan del presupuesto total
    known_clients: set[int] = field(default_factory=set)
    known_contacts: dict[int, int | None] = field(default_factory=dict)   # contact_id → client_id
    # Alcance conversacional (chat_scope): estado activo previo y señal del mensaje actual
    active_client_id: int | None = None
    active_contact_id: int | None = None
    active_label: str | None = None                   # p. ej. "Diputacion Costa Verde"
    scope: str | None = None                          # "global" | "contextual" | None
    # Ids aprendidos de resultados de ESTE turno (no solo del estado activo)
    learned_clients: set[int] = field(default_factory=set)
    learned_contacts: set[int] = field(default_factory=set)


@dataclass(frozen=True)
class Focus:
    """Entidades sobre las que trata un resultado (para el estado activo)."""
    clients: tuple[int, ...] = ()
    contacts: tuple[tuple[int, int | None], ...] = ()   # (contact_id, client_id)


@dataclass(frozen=True)
class ToolOutcome:
    """Traza de una llamada: name, argumentos validados, estado y resultado enviado al modelo."""
    name: str
    status: str                          # "ok" o un código de error
    result: dict
    arguments: dict | None = None
    focus: Focus = Focus()

    def summary(self) -> dict:
        """Versión compacta para persistir (sin los datos del CRM)."""
        return {"name": self.name, "args": self.arguments, "status": self.status,
                "found": self.result.get("found")}


def error_outcome(name: str, code: str, message: str, arguments: dict | None = None) -> ToolOutcome:
    return ToolOutcome(name=name, status=code, arguments=arguments,
                       result={"ok": False, "error": code, "message": message})


# =====================================================================
# Argumentos (esquema para OpenAI y validación en el backend a la vez)
# =====================================================================

class _Args(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


def _check_text(value: str | None, limit: int) -> str | None:
    # Las restricciones van en validadores (no en Field) para que el esquema
    # estricto que se envía a OpenAI solo use tipos, enums y null.
    if value is not None and (not value.strip() or len(value) > limit):
        raise ValueError(f"debe ser un texto no vacío de hasta {limit} caracteres")
    return value


def _check_limit(value: int | None, maximum: int) -> int | None:
    if value is not None and not 1 <= value <= maximum:
        raise ValueError(f"debe estar entre 1 y {maximum}")
    return value


def _check_id(value: int | None) -> int | None:
    if value is not None and value < 1:
        raise ValueError("debe ser un entero positivo")
    return value


# Filtros opcionales: el cliente/contacto activo NO es un valor por defecto (prueba real de G.4)
ClientId = Field(None, description="Solo si el mensaje actual nombra este cliente o se refiere a él "
                                   "(\"ellos\", \"ese cliente\"). Para preguntas generales (\"¿qué tengo mañana?\"), null: "
                                   "así se consultan todas tus actividades")
ContactId = Field(None, description="Solo si el mensaje actual nombra este contacto o se refiere a él (\"él\", "
                                    "\"con ella\"). Para preguntas generales, null")


class FindEntitiesArgs(_Args):
    client_name: str | None = Field(
        None, description="Nombre, alias o parte del nombre del cliente, tal como lo dice el usuario")
    contact_name: str | None = Field(
        None, description="Nombre de la persona de contacto (basta el nombre de pila), tal como lo dice el usuario")

    _texts = field_validator("client_name", "contact_name")(lambda v: _check_text(v, 200))

    @model_validator(mode="after")
    def _one(self):
        if self.client_name is None and self.contact_name is None:
            raise ValueError("indica client_name, contact_name o ambos")
        return self


class ListActivitiesArgs(_Args):
    client_id: int | None = ClientId
    contact_id: int | None = ContactId
    temporal_scope: Literal["today", "tomorrow", "yesterday", "this_week", "next_week", "last_week",
                            "upcoming", "past"] | None = Field(
        None, description="Ámbito temporal (semanas de lunes a domingo). Para la última actividad: past con "
                          "limit 1. Para otros periodos, date_from/date_to con el calendario del contexto")
    date_from: str | None = Field(None, description="Día inicial YYYY-MM-DD (inclusive)")
    date_to: str | None = Field(None, description="Día final YYYY-MM-DD (inclusive)")
    product_name: str | None = Field(
        None, description="Nombre o alias de un producto del catálogo: solo actividades donde se trató. "
                          "No añadas fechas ni temporal_scope salvo que el usuario diga un periodo")
    limit: int | None = Field(None, description="Máximo de actividades (1-20, por defecto 10)")

    _ids = field_validator("client_id", "contact_id")(_check_id)
    _product = field_validator("product_name")(lambda v: _check_text(v, 100))
    _limit = field_validator("limit")(lambda v: _check_limit(v, 20))


class SearchActivitiesArgs(_Args):
    query: str = Field(description="Tema a buscar en los comentarios de las actividades")
    client_id: int | None = ClientId

    _query = field_validator("query")(lambda v: _check_text(v, 300))
    _ids = field_validator("client_id")(_check_id)


class ClientArgs(_Args):
    client_id: int = Field(description="id del cliente (de find_entities, de otro resultado o del cliente activo)")

    _ids = field_validator("client_id")(_check_id)


class ContactArgs(_Args):
    contact_id: int = Field(description="id del contacto (de find_entities, de otro resultado o del contacto activo)")

    _ids = field_validator("contact_id")(_check_id)


class RankingsArgs(_Args):
    metric: Literal["activity_count", "inactivity", "billing", "attention", "product_discussed"] = Field(
        description="activity_count: clientes con más actividades del usuario; inactivity: más tiempo sin "
                    "actividad pasada; billing: más facturación (global); attention: señales para decidir a qué "
                    "clientes prestar atención (incluye los nunca contactados; ver rules); product_discussed: "
                    "productos más tratados en las actividades del usuario")
    limit: int | None = Field(None, description="Número de elementos (1-10, por defecto 5)")

    _limit = field_validator("limit")(lambda v: _check_limit(v, 10))


class CatalogArgs(_Args):
    query: str | None = Field(None, description="Texto a buscar en nombre o alias; null para todo el catálogo")
    limit: int | None = Field(None, description="Máximo de productos (1-20)")

    _query = field_validator("query")(lambda v: _check_text(v, 100))
    _limit = field_validator("limit")(lambda v: _check_limit(v, 20))


# =====================================================================
# Recorte de resultados (solo lo útil; ids solo donde sirven para encadenar)
# =====================================================================

def _clip(text, limit=COMMENT_CHARS):
    if not isinstance(text, str) or len(text) <= limit:
        return text
    return text[:limit - 1] + "…"


def _cap(items: list, limit: int, data: dict, key: str) -> None:
    data[key] = items[:limit]
    if len(items) > limit:
        data[f"{key}_omitted"] = len(items) - limit


def _ref(ref):
    return {"id": ref["id"], "name": ref["name"]} if ref else None


def _activity(a, comment_chars=COMMENT_CHARS):
    if a is None:
        return None
    return {
        "datetime": a["datetime"],
        "timing": a["timing"],
        "client": _ref(a["client"]),
        "contact": _ref(a["contact"]),
        "type": a["activity_type"]["name"] if a["activity_type"] else None,
        "comment": _clip(a["comment"], comment_chars),
        "products": [p["name"] for p in a["products"]],
    }


def _activity_summary(s):
    return {
        "scope": s["scope"], "total": s["total"], "past": s["past"], "upcoming": s["upcoming"],
        "last_activity": _activity(s["last_activity"]), "next_activity": _activity(s["next_activity"]),
        "by_type": [{"type": t["activity_type"]["name"] if t["activity_type"] else None, "count": t["count"]}
                    for t in s["by_type"]],
    }


def _overview(r):
    c, b = r["client"], r["billing"]
    data = {
        "found": True,
        "client": {"id": c["id"], "name": c["name"], "alias": c["alias"], "group": c["group"], "city": c["city"]},
        "activity": _activity_summary(r["activity"]),
        "billing": {
            "scope": b["scope"], "total_billed": b["total_billed"], "invoice_count": b["invoice_count"],
            "average_ticket": b["average_ticket"], "last_invoice_date": b["last_invoice_date"],
            "top_product": b["top_product"]["name"] if b["top_product"] else None,
        },
        "products": {},
    }
    # Sin teléfono ni email: datos de contacto solo con get_contact (petición explícita)
    _cap([{k: x[k] for k in ("id", "name", "role")} for x in r["contacts"]], 10, data, "contacts")
    _cap(_discussed(r["products"]["discussed"]), 8, data["products"], "discussed")
    _cap(_invoiced(r["products"]["invoiced"]), 8, data["products"], "invoiced")
    return data


def _discussed(items):
    return [{"name": p["name"], "activity_count": p["activity_count"],
             "last_activity_datetime": p["last_activity_datetime"]} for p in items]


def _invoiced(items):
    return [{"name": p["name"], "total_billed": p["total_billed"], "quantity": p["quantity"],
             "invoice_count": p["invoice_count"], "last_invoice_date": p["last_invoice_date"]} for p in items]


def _not_found(result):
    return {"found": False}


FIND_ENTITIES_NOTE = ("Solo identifica a quién se refiere el usuario: no contiene actividades, contactos del "
                      "cliente ni facturación (contact.candidates vacío NO significa que no tenga contactos). "
                      "Para hablar del cliente o contacto, consulta después la herramienta de datos que corresponda.")


def shape_find_entities(r):
    client, contact = r["client"], r["contact"]
    # Con un conflicto (contacto que no es de ese cliente) no sale ningún id:
    # el modelo tiene que resolver de nuevo sin contradicción para poder usarlos
    conflict = "conflict" in (client["status"], contact["status"])

    def trusted(value):
        return None if conflict else value

    return {
        "found": r["found"],
        # G.6: el modelo leía contact.candidates vacío como "el cliente no tiene contactos"
        "note": FIND_ENTITIES_NOTE,
        # id solo si está resuelto; los candidatos van SIN id (no son de confianza)
        "client": {"id": trusted(client["id"]), "name": client["name"], "said": client["mention"],
                   "status": client["status"], "candidates": [c["name"] for c in client["candidates"]]},
        "contact": {"id": trusted(contact["id"]), "name": contact["name"], "client_id": trusted(contact["client_id"]),
                    "said": contact["mention"], "status": contact["status"],
                    "candidates": [{"name": c["name"], "client_name": c["client_name"]}
                                   for c in contact["candidates"]]},
    }


def shape_list_activities(r):
    data = {"found": r["found"], "count": r["count"], "has_more": r["has_more"],
            "activities": [_activity(a, LIST_COMMENT_CHARS) for a in r["activities"]]}
    if r.get("product_filter"):
        data["product_filter"] = r["product_filter"]   # solo nombres: nunca ids de producto
    return data


def shape_search_activities(r):
    return {"found": r["found"], "count": r["count"],
            "note": "score = similitud relativa con la consulta, no prueba de que se hablara de ello",
            "results": [{"score": round(x["score"], 2), "activity": _activity(x["activity"], LIST_COMMENT_CHARS)}
                        for x in r["results"]]}


def shape_client_overview(r):
    return _overview(r) if r["found"] else _not_found(r)


def shape_contact(r):
    if not r["found"]:
        return _not_found(r)
    # client_id en el propio contacto: es la relación real (JOIN con contacts)
    data = {"found": True, "contact": {**r["contact"], "client_id": r["client"]["id"]}, "client": r["client"],
            "activity": _activity_summary(r["activity"])}
    _cap([_activity(a) for a in r["recent_activities"]], 5, data, "recent_activities")
    return data


def shape_rankings(r):
    data = {k: v for k, v in r.items() if k != "now"}
    data["items"] = list(r["items"])
    return data


def shape_catalog(r):
    return {"found": r["found"], "source": r["source"], "count": r["count"], "has_more": r["has_more"],
            "products": [{"name": p["name"], "price": p["price"], "aliases": p["aliases"]} for p in r["products"]]}


def shape_client_products(r):
    if not r["found"]:
        return _not_found(r)
    data = {"found": True, "client": r["client"],
            "note": "discussed = mencionado en tus actividades (no implica compra); invoiced = facturado (global)"}
    _cap(_discussed(r["discussed"]), 10, data, "discussed")
    _cap(_invoiced(r["invoiced"]), 10, data, "invoiced")
    return data


def shape_meeting_context(r):
    if not r["found"]:
        return _not_found(r)
    data = _overview(r)
    data["last_contact_datetime"] = r["last_contact_datetime"]
    data["recent_activities"] = [_activity(a) for a in r["recent_activities"]]
    data["upcoming_activities"] = [_activity(a) for a in r["upcoming_activities"]]
    data["rule_signals"] = [s["text"] for s in r["rule_signals"]]
    return data


def fit_result(result: dict, limit: int = MAX_RESULT_CHARS) -> dict:
    """
    Guarda de tamaño determinista: mientras el JSON supere `limit`, quita el
    último elemento de la lista más grande y marca truncated.
    """
    def size(value):
        return len(json.dumps(value, ensure_ascii=False))

    def lists(value):
        if isinstance(value, dict):
            for item in value.values():
                yield from lists(item)
        elif isinstance(value, list):
            if value:
                yield value
            for item in value:
                yield from lists(item)

    while size(result) > limit:
        candidates = list(lists(result))
        if not candidates:
            return {"ok": False, "error": "result_too_large", "message": "Resultado demasiado grande."}
        max(candidates, key=size).pop()
        result["truncated"] = True
    return result


# =====================================================================
# Ids conocidos y foco
# =====================================================================

def learn_ids(value, ctx: ToolContext) -> None:
    """
    Registra los ids de clientes y contactos que aparecen en un resultado ya
    recortado: {"client": {"id"}}, {"contact": {"id", "client_id"?}} y
    {"contacts": [{"id"}]}.

    La relación contacto → cliente solo se toma de fuentes que la establecen
    (JOIN con contacts): el client_id del propio contacto (find_entities,
    get_contact) y la lista "contacts" de la ficha de un cliente. Nunca del
    cliente "vecino" en una actividad: activities no garantiza que su contacto
    sea de su cliente. Un contacto sin relación conocida queda con None.
    """
    if isinstance(value, list):
        for item in value:
            learn_ids(item, ctx)
        return
    if not isinstance(value, dict):
        return

    client = value.get("client")
    client_id = client["id"] if isinstance(client, dict) and isinstance(client.get("id"), int) else None
    if client_id is not None:
        ctx.known_clients.add(client_id)
        ctx.learned_clients.add(client_id)

    contact = value.get("contact")
    if isinstance(contact, dict) and isinstance(contact.get("id"), int):
        owner = contact.get("client_id")
        if isinstance(owner, int):
            ctx.known_contacts[contact["id"]] = owner
            ctx.known_clients.add(owner)
            ctx.learned_clients.add(owner)
        else:
            ctx.known_contacts.setdefault(contact["id"], None)
        ctx.learned_contacts.add(contact["id"])

    # Contactos de la ficha del cliente de este mismo nivel (consulta WHERE client_id = ?)
    contacts = value.get("contacts")
    if client_id is not None and isinstance(contacts, list):
        for item in contacts:
            if isinstance(item, dict) and isinstance(item.get("id"), int):
                ctx.known_contacts[item["id"]] = client_id
                ctx.learned_contacts.add(item["id"])

    for key, item in value.items():
        if key not in ("client", "contact", "contacts"):
            learn_ids(item, ctx)


def _focus_args(args, ctx) -> Focus:
    """Foco de una consulta filtrada por cliente/contacto (aunque no haya actividades)."""
    clients = (args.client_id,) if getattr(args, "client_id", None) else ()
    contact_id = getattr(args, "contact_id", None)
    contacts = ((contact_id, ctx.known_contacts.get(contact_id)),) if contact_id else ()
    return Focus(clients=clients, contacts=contacts)


def _focus_found_client(args, result, ctx) -> Focus:
    return Focus(clients=(args.client_id,)) if result["found"] else Focus()


def _focus_contact(args, result, ctx) -> Focus:
    if not result["found"]:
        return Focus()
    return Focus(contacts=((result["contact"]["id"], result["client"]["id"]),))


def _focus_find_entities(args, result, ctx) -> Focus:
    client, contact = result["client"], result["contact"]
    if "conflict" in (client["status"], contact["status"]):
        return Focus()  # contradicción: no se cambia el contexto
    clients = (client["id"],) if client["id"] else ()
    contacts = ((contact["id"], contact["client_id"]),) if contact["id"] else ()
    return Focus(clients=clients, contacts=contacts)


def _no_focus(args, result, ctx) -> Focus:
    return Focus()


# =====================================================================
# Registro
# =====================================================================

@dataclass(frozen=True)
class ChatTool:
    name: str
    description: str
    args: type[_Args]
    run: Callable[[_Args, ToolContext], dict]
    shape: Callable[[dict], dict]
    focus: Callable[[_Args, dict, ToolContext], Focus]


def _search(args: SearchActivitiesArgs, ctx: ToolContext) -> dict:
    timeout = min(EMBEDDING_TIMEOUT_S, ctx.remaining())
    if timeout < MIN_EMBEDDING_TIMEOUT_S:
        raise AIServiceError("search_activities")  # sin presupuesto: como si la IA no respondiera
    return crm_tools.search_activities(args.query, ctx.salesperson_id, client_id=args.client_id,
                                       limit=5, now=ctx.now, timeout=timeout)


_TOOLS = (
    ChatTool(
        "find_entities",
        "Busca clientes y/o contactos del CRM por el nombre, alias o parte del nombre que use el usuario "
        "(no hace falta el nombre completo) y devuelve sus ids. Úsala siempre que el mensaje nombre a un "
        "cliente o contacto, haya o no cliente activo, y antes de cualquier herramienta que necesite un id. "
        "status: exact/fuzzy/inherited = resuelto; partial = resuelto por coincidencia parcial de palabras "
        "(di cómo lo has entendido); ambiguous = varios candidatos (pregunta al usuario); unresolved = no existe; "
        "conflict = el contacto no es de ese cliente. Solo identifica: no devuelve actividades, contactos del "
        "cliente ni facturación.",
        FindEntitiesArgs,
        lambda a, ctx: crm_tools.find_entities(None, ctx.salesperson_id, client_name=a.client_name,
                                               contact_name=a.contact_name),
        shape_find_entities, _focus_find_entities,
    ),
    ChatTool(
        "list_activities",
        "Actividades (agenda e historial) del usuario. Sin client_id ni contact_id busca en TODAS sus actividades. "
        "Filtros opcionales: cliente, contacto, ámbito temporal, fechas y producto tratado. Para \"¿con qué "
        "clientes se habló de un producto?\" usa product_name: product_filter.by_client resume por cliente "
        "(si el producto es ambiguo o no existe, product_filter lo indica).",
        ListActivitiesArgs,
        lambda a, ctx: crm_tools.list_activities(
            ctx.salesperson_id, client_id=a.client_id, contact_id=a.contact_id, temporal_scope=a.temporal_scope,
            date_from=a.date_from, date_to=a.date_to, product_name=a.product_name,
            limit=a.limit or LIST_DEFAULT_LIMIT, now=ctx.now),
        shape_list_activities, lambda a, r, ctx: _focus_args(a, ctx),
    ),
    ChatTool(
        "search_activities",
        "Búsqueda por significado en los comentarios de las actividades del usuario (temas libres, p. ej. de qué "
        "se habló). Para un producto del catálogo usa list_activities con product_name.",
        SearchActivitiesArgs, _search, shape_search_activities, lambda a, r, ctx: _focus_args(a, ctx),
    ),
    ChatTool(
        "get_client_overview",
        "Ficha de un cliente: contactos, resumen de actividad del usuario, facturación global y productos.",
        ClientArgs,
        lambda a, ctx: crm_tools.get_client_overview(a.client_id, ctx.salesperson_id, now=ctx.now),
        shape_client_overview, _focus_found_client,
    ),
    ChatTool(
        "get_contact",
        "Datos de un contacto, su cliente y la actividad del usuario con él.",
        ContactArgs,
        lambda a, ctx: crm_tools.get_contact(a.contact_id, ctx.salesperson_id, now=ctx.now),
        shape_contact, _focus_contact,
    ),
    ChatTool(
        "crm_rankings",
        "Rankings deterministas: clientes por actividad del usuario, inactividad, facturación global o señales "
        "de atención (attention), y productos más tratados (product_discussed).",
        RankingsArgs,
        lambda a, ctx: crm_tools.crm_rankings(a.metric, ctx.salesperson_id, limit=a.limit, now=ctx.now),
        shape_rankings, _no_focus,
    ),
    ChatTool(
        "search_product_catalog",
        "Catálogo global de productos (nombre, precio, alias). No dice nada de ningún cliente.",
        CatalogArgs,
        lambda a, ctx: crm_tools.search_product_catalog(a.query, limit=a.limit),
        shape_catalog, _no_focus,
    ),
    ChatTool(
        "get_client_products",
        "Productos tratados en las actividades del usuario con un cliente y productos facturados a ese cliente.",
        ClientArgs,
        lambda a, ctx: crm_tools.get_client_products(a.client_id, ctx.salesperson_id),
        shape_client_products, _focus_found_client,
    ),
    ChatTool(
        "prepare_meeting_context",
        "Datos para preparar una reunión con un cliente: ficha, últimas y próximas actividades del usuario y señales.",
        ClientArgs,
        lambda a, ctx: crm_tools.prepare_meeting_context(a.client_id, ctx.salesperson_id, now=ctx.now),
        shape_meeting_context, _focus_found_client,
    ),
)

REGISTRY: dict[str, ChatTool] = {tool.name: tool for tool in _TOOLS}

TOOL_SCHEMAS = [openai.pydantic_function_tool(t.args, name=t.name, description=t.description) for t in _TOOLS]


# =====================================================================
# Ejecución validada
# =====================================================================

def _validation_message(error: ValidationError) -> str:
    # Solo campo + motivo: pydantic no incluye aquí el valor recibido
    return "; ".join(f"{'.'.join(map(str, e['loc'])) or 'argumentos'}: {e['msg']}" for e in error.errors())


def _unknown_id(args: _Args, ctx: ToolContext) -> str | None:
    client_id = getattr(args, "client_id", None)
    if client_id is not None and client_id not in ctx.known_clients:
        return "client_id"
    contact_id = getattr(args, "contact_id", None)
    if contact_id is not None and contact_id not in ctx.known_contacts:
        return "contact_id"
    return None


# Consultas de actividades que el contexto activo podría estrechar sin que el usuario lo pida
SCOPE_GUARDED_TOOLS = {"list_activities", "search_activities"}


def _scoped_only_by_active_state(args: _Args, ctx: ToolContext) -> bool:
    """El filtro de cliente/contacto sale SOLO del estado activo previo (nada de este turno lo respalda)."""
    client_id = getattr(args, "client_id", None)
    contact_id = getattr(args, "contact_id", None)
    client_from_state = (client_id is not None and client_id == ctx.active_client_id
                         and client_id not in ctx.learned_clients)
    contact_from_state = (contact_id is not None and contact_id == ctx.active_contact_id
                          and contact_id not in ctx.learned_contacts)
    return client_from_state or contact_from_state


def _scope_guard(name: str, args: _Args, ctx: ToolContext, arguments: dict) -> ToolOutcome | None:
    """
    Alcance ambiguo o contradictorio (prueba real de G.4): una consulta de
    actividades acotada solo con el contexto activo, cuando el mensaje no se
    refiere a él, no se ejecuta (daría un "no tienes nada" engañoso).
    """
    if name not in SCOPE_GUARDED_TOOLS or not _scoped_only_by_active_state(args, ctx):
        return None
    if ctx.scope == "global":
        return error_outcome(name, "scope_global",
                             "El usuario pide todas sus actividades: repite la consulta sin client_id ni contact_id.",
                             arguments)
    if ctx.scope is None:
        label = ctx.active_label or "el cliente activo"
        return error_outcome(name, "scope_ambiguous",
                             f"La pregunta no dice si es sobre {label} o sobre todas las actividades del usuario. "
                             f"No consultes nada más: pregunta «¿Te refieres a {label} o a todas tus actividades?».",
                             arguments)
    return None


def dispatch(name: str, raw_arguments: str, ctx: ToolContext) -> ToolOutcome:
    """
    Valida y ejecuta UNA llamada pedida por el modelo. Nunca lanza: todo fallo
    es un resultado controlado. No amplía los ids conocidos (ver trust_result).
    """
    tool = REGISTRY.get(name)
    if tool is None:
        return error_outcome(str(name)[:64], "unknown_tool", "Esa herramienta no existe.")

    try:
        args = tool.args.model_validate_json(raw_arguments)
    except ValidationError as error:
        return error_outcome(name, "invalid_arguments", _validation_message(error))
    arguments = args.model_dump(exclude_none=True)

    field_name = _unknown_id(args, ctx)
    if field_name:
        return error_outcome(name, "unknown_id",
                             f"{field_name} desconocido: resuelve antes el nombre con find_entities "
                             "o usa el id del contexto activo.", arguments)

    guarded = _scope_guard(name, args, ctx, arguments)
    if guarded:
        return guarded

    try:
        raw = tool.run(args, ctx)
    except ToolArgumentError as error:
        return error_outcome(name, "invalid_arguments", str(error), arguments)
    except AIServiceError:
        return error_outcome(name, "tool_unavailable", "La búsqueda no está disponible ahora mismo.", arguments)
    except Exception:
        logger.exception("Fallo de la herramienta del chat %s", name)
        return error_outcome(name, "tool_failed", "No se han podido consultar estos datos.", arguments)

    result = fit_result({"ok": True, **tool.shape(raw)})
    if not result.get("ok"):
        return ToolOutcome(name=name, status=result["error"], result=result, arguments=arguments)

    # Sus ids aún NO son de confianza: lo serán con trust_result si el resultado
    # llega de verdad al modelo (puede descartarse por el tope de evidencia)
    return ToolOutcome(name=name, status="ok", result=result, arguments=arguments,
                       focus=tool.focus(args, raw, ctx))


def trust_result(outcome: ToolOutcome, ctx: ToolContext) -> None:
    """Los ids de un resultado correcto pasan a ser conocidos cuando se envía al modelo."""
    if outcome.status == "ok":
        learn_ids(outcome.result, ctx)


# =====================================================================
# Estado activo derivado de la traza (nunca del texto del modelo)
# =====================================================================

def derive_state(client_id: int | None, contact: tuple[int, int | None] | None,
                 outcomes: list[ToolOutcome]) -> tuple[int | None, int | None]:
    """
    Nuevo (client_id, contact_id) a partir de las llamadas correctas del turno:
    - un único cliente enfocado → activo; ninguno → se conserva; varios → ninguno;
    - un único contacto enfocado → activo, y su cliente cuenta como enfocado;
    - el contacto activo se descarta si su cliente deja de ser el activo.
    `contact` es el contacto activo previo como (contact_id, client_id).
    """
    focused_clients: list[int] = []
    focused_contacts: list[tuple[int, int | None]] = []
    for outcome in outcomes:
        if outcome.status != "ok":
            continue
        for c in outcome.focus.clients:
            if c not in focused_clients:
                focused_clients.append(c)
        for pair in outcome.focus.contacts:
            if pair[0] not in [p[0] for p in focused_contacts]:
                focused_contacts.append(pair)
            if pair[1] is not None and pair[1] not in focused_clients:
                focused_clients.append(pair[1])

    if len(focused_contacts) == 1:
        contact = focused_contacts[0]
    elif len(focused_contacts) > 1:
        contact = None

    if len(focused_clients) == 1:
        client_id = focused_clients[0]
    elif len(focused_clients) > 1:
        client_id = None

    # Un contacto solo queda activo con su cliente de confianza como cliente activo
    if contact is not None and (contact[1] is None or contact[1] != client_id):
        contact = None
    return client_id, contact[0] if contact else None
