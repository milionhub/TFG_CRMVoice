"""
Esquemas del Action Engine (H.2).

1. Interpretation: lo ÚNICO que produce el modelo (Structured Outputs,
   esquema estricto). Solo MENCIONES en texto: nunca ids. Todos los campos
   son obligatorios (null o lista vacía si no aplican), como exige el modo strict;
   los que tienen valor por defecto en Python (I.7) también son obligatorios
   en el esquema que se envía al modelo (el SDK los marca como required).
2. Campos de un borrador ya resuelto (ResolvedRef con ids del resolvedor
   determinista) por tipo de acción.
3. Peticiones de la API (interpretar, editar, confirmar) y la vista pública
   del borrador (DraftView, que nunca incluye la interpretación en bruto).
"""
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictInt, StrictStr

from schemas.issues import Candidate, Issue

# I.8: acciones del catálogo de productos (también en el CHECK de action_drafts, migración m006)
ActionType = Literal["create_activity", "create_client", "create_contact", "create_sale",
                     "create_product", "update_product"]
ACTION_TYPES: tuple[str, ...] = ("create_activity", "create_client", "create_contact", "create_sale",
                                 "create_product", "update_product")
DraftStatus = Literal["open", "executed", "cancelled"]
DraftSource = Literal["voice", "text", "chat"]
MAX_SOURCE_TEXT = 2000

# Los 5 tipos de actividad que crea init_db (db.ACTIVITY_TYPES); un test comprueba que coinciden
ActivityTypeName = Literal["Concertar reunión", "Enviar presupuesto", "Enviar oferta",
                           "Registrar visita comercial", "Realizar llamada de seguimiento"]


# =====================================================================
# 1. Salida del modelo (strict): menciones, nunca ids
# =====================================================================

class _LLM(BaseModel):
    model_config = ConfigDict(extra="forbid")


class NewClientMention(_LLM):
    name: str | None
    alias: str | None
    city: str | None
    province: str | None
    group_name: str | None
    # I.7: datos de contacto del cliente tal como se dicen (los normaliza core.structured_values)
    phone: str | None = None
    email: str | None = None
    cif: str | None = None


class NewContactMention(_LLM):
    name: str | None
    role: str | None
    email: str | None
    phone: str | None


class SaleLineMention(_LLM):
    product_name: str | None
    concept: str | None
    quantity: int | None
    amount: str | None               # decimal con punto: "4500.00"
    amount_is_unit_price: bool


class ProductMention(_LLM):
    """I.8: producto nuevo (create_product) o existente (update_product), tal como se dice."""
    name: str | None                 # nombre dicho (el nuevo, o el del producto existente)
    price: str | None                # PVP en euros con punto decimal: "89.00"
    new_name: str | None             # nuevo nombre (update_product)


class Interpretation(_LLM):
    action_type: Literal["create_activity", "create_client", "create_contact", "create_sale",
                         "create_product", "update_product", "unsupported"]
    client_name: str | None
    contact_name: str | None
    activity_type: ActivityTypeName | None
    date: str | None                 # AAAA-MM-DD
    # I.7: el día tal como se dijo ("pasado mañana", "el próximo lunes"); lo resuelve core.relative_dates
    date_said: str | None = None
    time: str | None                 # HH:MM
    status: Literal["pending", "completed"] | None
    products: list[str]
    comment: str | None
    new_client: NewClientMention | None
    new_contact: NewContactMention | None
    sale_lines: list[SaleLineMention]
    sale_date: str | None
    unsupported_reason: str | None
    # I.8 (con valor por defecto en Python; obligatorios en el esquema del modelo)
    product: ProductMention | None = None


# =====================================================================
# 2. Borrador resuelto (lo que se guarda y lo que se escribirá al confirmar)
# =====================================================================

class ResolvedRef(BaseModel):
    """Entidad del CRM: id SOLO del resolvedor determinista (o elegido por el usuario y revalidado)."""
    model_config = ConfigDict(extra="forbid")

    id: int | None = None
    label: str | None = None                  # nombre oficial
    said: str | None = None                   # lo que dijo el usuario / la transcripción
    match: Literal["exact", "fuzzy", "partial", "inherited", "user_selected", "new"] | None = None
    problem: Literal["ambiguous", "not_found", "conflict"] | None = None
    candidates: list[Candidate] = []          # emitidos por el servidor
    evidence: str | None = None               # I.7: por qué se resolvió por contexto (visible en el aviso)


class ActivityDraft(BaseModel):
    model_config = ConfigDict(extra="forbid")

    client: ResolvedRef | None = None
    contact: ResolvedRef | None = None
    activity_type: ResolvedRef | None = None
    date: str | None = None
    time: str | None = None
    time_defaulted: bool = False              # completada sin hora: se usó la hora actual (visible)
    status: Literal["pending", "completed"] | None = None
    products: list[ResolvedRef] = []
    comment: str | None = None


class ClientDraft(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str | None = None
    alias: str | None = None
    city: str | None = None
    province: str | None = None
    group: ResolvedRef | None = None
    phone: str | None = None
    email: str | None = None
    cif: str | None = None


class ContactDraft(BaseModel):
    model_config = ConfigDict(extra="forbid")

    client: ResolvedRef | None = None
    name: str | None = None
    role: str | None = None
    email: str | None = None
    phone: str | None = None


class SaleLineDraft(BaseModel):
    model_config = ConfigDict(extra="forbid")

    product: ResolvedRef | None = None
    concept: str | None = None
    quantity: int | None = None
    amount_cents: int | None = None           # TOTAL de la línea
    amount_said: str | None = None            # el importe tal como llegó (para mostrar errores)
    amount_error: str | None = None
    reference_total_cents: int | None = None  # precio de catálogo x cantidad: SOLO informativo


class SaleDraft(BaseModel):
    model_config = ConfigDict(extra="forbid")

    client: ResolvedRef | None = None
    contact: ResolvedRef | None = None
    sale_date: str | None = None
    lines: list[SaleLineDraft] = []
    notes: str | None = None


class ProductDraft(BaseModel):
    """create_product: producto NUEVO (nunca se resuelve contra uno existente)."""
    model_config = ConfigDict(extra="forbid")

    name: str | None = None
    price_cents: int | None = None            # PVP
    price_said: str | None = None
    price_error: str | None = None


class ProductUpdateDraft(BaseModel):
    """update_product: SOLO los cambios (None = no cambia) y los valores actuales, para mostrarlos."""
    model_config = ConfigDict(extra="forbid")

    product: ResolvedRef | None = None
    name: str | None = None                   # nuevo nombre
    price_cents: int | None = None            # nuevo PVP
    price_said: str | None = None
    price_error: str | None = None
    current_name: str | None = None
    current_price_cents: int | None = None


DRAFT_MODELS = {"create_activity": ActivityDraft, "create_client": ClientDraft,
                "create_contact": ContactDraft, "create_sale": SaleDraft,
                "create_product": ProductDraft, "update_product": ProductUpdateDraft}


# =====================================================================
# 3. API
# =====================================================================

class _Request(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class InterpretTextRequest(_Request):
    text: str = Field(min_length=1, max_length=MAX_SOURCE_TEXT)


class ConfirmRequest(_Request):
    """Confirmar NO acepta datos de negocio: solo la revisión que el usuario ha visto."""
    revision: int = Field(ge=1)


class DraftPatch(_Request):
    revision: int = Field(ge=1)
    edits: dict                               # se valida con el modelo del tipo de acción (abajo)


class ActivityEdits(_Request):
    client_id: int | None = None
    client_name: str | None = Field(None, max_length=120)
    contact_id: int | None = None             # null explícito = sin contacto
    contact_name: str | None = Field(None, max_length=80)
    activity_type_id: int | None = None
    date: str | None = None
    time: str | None = None
    status: Literal["pending", "completed"] | None = None
    product_ids: list[int] | None = Field(None, max_length=10)
    product_names: list[str] | None = Field(None, max_length=10)
    comment: str | None = Field(None, max_length=2000)


class ClientEdits(_Request):
    name: str | None = Field(None, max_length=120)
    alias: str | None = Field(None, max_length=60)
    city: str | None = Field(None, max_length=80)
    province: str | None = Field(None, max_length=80)
    group_id: int | None = None
    phone: str | None = Field(None, max_length=30)
    email: str | None = Field(None, max_length=120)
    cif: str | None = Field(None, max_length=20)


class ContactEdits(_Request):
    client_id: int | None = None
    client_name: str | None = Field(None, max_length=120)
    name: str | None = Field(None, max_length=80)
    role: str | None = Field(None, max_length=80)
    email: str | None = None
    phone: str | None = None


class SaleLineEdit(_Request):
    product_id: int | None = None
    product_name: str | None = Field(None, max_length=120)
    concept: str | None = Field(None, max_length=200)
    quantity: int | None = Field(None, ge=1, le=100_000)
    amount: StrictInt | StrictStr | None = None


class SaleEdits(_Request):
    client_id: int | None = None
    client_name: str | None = Field(None, max_length=120)
    contact_id: int | None = None
    contact_name: str | None = Field(None, max_length=80)
    sale_date: str | None = None
    lines: list[SaleLineEdit] | None = Field(None, min_length=1, max_length=5)
    notes: str | None = Field(None, max_length=500)


class ProductEdits(_Request):
    name: str | None = Field(None, max_length=100)
    price: StrictInt | StrictStr | None = None


class ProductUpdateEdits(_Request):
    product_id: int | None = None
    product_name: str | None = Field(None, max_length=120)
    name: str | None = Field(None, max_length=100)        # null explícito = no cambiar el nombre
    price: StrictInt | StrictStr | None = None            # null explícito = no cambiar el PVP


EDIT_MODELS = {"create_activity": ActivityEdits, "create_client": ClientEdits,
               "create_contact": ContactEdits, "create_sale": SaleEdits,
               "create_product": ProductEdits, "update_product": ProductUpdateEdits}


class DraftView(BaseModel):
    """Vista pública del borrador (sin la interpretación en bruto del modelo)."""
    id: str
    action_type: ActionType
    status: DraftStatus
    revision: int
    source: DraftSource
    source_text: str
    fields: dict
    issues: list[Issue]
    confirmable: bool
    expired: bool
    expires_at: str
    result: dict | None = None
    created_at: str
    updated_at: str
