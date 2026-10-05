"""
Esquemas del Action Engine (H.2).

1. Interpretation: lo ÚNICO que produce el modelo (Structured Outputs,
   esquema estricto). Solo MENCIONES en texto: nunca ids. Todos los campos
   son obligatorios (null o lista vacía si no aplican), como exige el modo strict.
2. Campos de un borrador ya resuelto (ResolvedRef con ids del resolvedor
   determinista) por tipo de acción.
3. Peticiones de la API (interpretar, editar, confirmar) y la vista pública
   del borrador (DraftView, que nunca incluye la interpretación en bruto).
"""
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictInt, StrictStr

from schemas.issues import Candidate, Issue

ActionType = Literal["create_activity", "create_client", "create_contact", "create_sale"]
ACTION_TYPES: tuple[str, ...] = ("create_activity", "create_client", "create_contact", "create_sale")
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


class Interpretation(_LLM):
    action_type: Literal["create_activity", "create_client", "create_contact", "create_sale", "unsupported"]
    client_name: str | None
    contact_name: str | None
    activity_type: ActivityTypeName | None
    date: str | None                 # AAAA-MM-DD
    time: str | None                 # HH:MM
    status: Literal["pending", "completed"] | None
    products: list[str]
    comment: str | None
    new_client: NewClientMention | None
    new_contact: NewContactMention | None
    sale_lines: list[SaleLineMention]
    sale_date: str | None
    unsupported_reason: str | None


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


DRAFT_MODELS = {"create_activity": ActivityDraft, "create_client": ClientDraft,
                "create_contact": ContactDraft, "create_sale": SaleDraft}


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


EDIT_MODELS = {"create_activity": ActivityEdits, "create_client": ClientEdits,
               "create_contact": ContactEdits, "create_sale": SaleEdits}


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
