"""
Entradas tipadas de las escrituras del CRM (H.2): clientes, contactos,
actividades y ventas. Las usan igual los endpoints REST y la confirmación
de un borrador del Action Engine (un borrador se convierte en uno de estos).

Aquí solo se valida la FORMA (tipos, longitudes, formatos). Las reglas de
negocio (que existan las referencias, contacto ∈ cliente, duplicados,
estado/fecha...) están en services/writes.
"""
import re
from typing import Literal

from pydantic import (BaseModel, ConfigDict, Field, PrivateAttr, StrictInt, StrictStr, field_validator,
                      model_validator)

from core.formats import FormatError, capitalize_first, normalize_datetime, parse_date, parse_money_cents

ActivityStatus = Literal["pending", "completed", "cancelled"]

_EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")
_PHONE = re.compile(r"[0-9 +\-()]{6,20}")


class StrictModel(BaseModel):
    """Escrituras: sin campos desconocidos y con los textos ya recortados."""
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


def _blank_to_none(value):
    return None if isinstance(value, str) and not value.strip() else value


def _check_email(value):
    if value is not None and (len(value) > 120 or not _EMAIL.fullmatch(value)):
        raise ValueError("Email no válido")
    return value


def _capitalize(value):
    """Mayúscula inicial prudente (core.formats.capitalize_first, H4-03)."""
    return capitalize_first(value)


def _check_phone(value):
    if value is not None and not _PHONE.fullmatch(value):
        raise ValueError("Teléfono no válido (6 a 20 caracteres: dígitos, espacios, +, - o paréntesis)")
    return value


# =====================================================================
# Clientes (compartidos por todos los comerciales)
# =====================================================================

class ClientIn(StrictModel):
    """Alta y edición (PUT = sustitución completa de estos campos)."""
    name: str = Field(min_length=2, max_length=120)          # razón social
    alias: str | None = Field(None, max_length=60)
    city: str | None = Field(None, max_length=80)            # población
    province: str | None = Field(None, max_length=80)
    group_id: int | None = None
    phone: str | None = None
    email: str | None = None
    cif: str | None = Field(None, max_length=20)

    _blanks = field_validator("alias", "city", "province", "phone", "email", "cif", mode="before")(_blank_to_none)
    _email = field_validator("email")(_check_email)
    _phone = field_validator("phone")(_check_phone)


# =====================================================================
# Contactos (pertenecen siempre a un cliente)
# =====================================================================

class ContactFields(StrictModel):
    name: str = Field(min_length=2, max_length=80)
    role: str | None = Field(None, max_length=80)            # cargo
    email: str | None = None
    phone: str | None = None

    _blanks = field_validator("role", "email", "phone", mode="before")(_blank_to_none)
    _role = field_validator("role")(_capitalize)
    _email = field_validator("email")(_check_email)
    _phone = field_validator("phone")(_check_phone)


class ContactIn(ContactFields):
    client_id: int


class ContactUpdate(ContactFields):
    """Sin client_id: un contacto no cambia de cliente (rompería sus actividades)."""


# =====================================================================
# Actividades (del comercial)
# =====================================================================

class ActivityIn(StrictModel):
    """Alta y edición (PUT = sustitución completa). El comercial sale del token."""
    client_id: int
    contact_id: int | None = None
    activity_type_id: int
    datetime: str                                            # "YYYY-MM-DDTHH:MM[:SS]", hora local
    status: ActivityStatus
    product_ids: list[int] = Field(default_factory=list, max_length=10)
    comment: str | None = Field(None, max_length=2000)

    _comment = field_validator("comment", mode="before")(_blank_to_none)

    @field_validator("datetime")
    @classmethod
    def _datetime(cls, value):
        try:
            return normalize_datetime(value)
        except FormatError as error:
            raise ValueError(str(error)) from None

    @field_validator("product_ids")
    @classmethod
    def _unique_products(cls, value):
        if len(set(value)) != len(value):
            raise ValueError("Producto repetido")
        return value


class ActivityStatusPatch(StrictModel):
    status: ActivityStatus


# =====================================================================
# Ventas (del comercial): una fila = una línea, importe TOTAL en céntimos
# =====================================================================

def cents_to_text(cents: int) -> str:
    return f"{cents // 100}.{cents % 100:02d}"


class SaleLineIn(StrictModel):
    product_id: int | None = None
    concept: str | None = Field(None, max_length=200)
    quantity: int | None = Field(None, ge=1, le=100_000)
    amount: StrictInt | StrictStr        # TOTAL de la línea en euros: 4500 · "4.500" · "4.500,00"

    _amount_cents: int = PrivateAttr()
    _concept = field_validator("concept", mode="before")(_blank_to_none)
    _concept_case = field_validator("concept")(_capitalize)

    @model_validator(mode="after")
    def _parse_amount(self):
        try:
            self._amount_cents = parse_money_cents(self.amount)
        except FormatError as error:
            raise ValueError(str(error)) from None
        return self

    @property
    def amount_cents(self) -> int:
        return self._amount_cents


def _check_sale_date(value):
    if value is None:
        return value
    try:
        return parse_date(value).isoformat()
    except FormatError as error:
        raise ValueError(str(error)) from None


class SaleCreate(StrictModel):
    """1 a 5 líneas que se guardan juntas (todas o ninguna). sale_date por defecto: hoy."""
    client_id: int
    contact_id: int | None = None
    sale_date: str | None = None                             # "YYYY-MM-DD"
    notes: str | None = Field(None, max_length=500)
    lines: list[SaleLineIn] = Field(min_length=1, max_length=5)

    _notes = field_validator("notes", mode="before")(_blank_to_none)
    _date = field_validator("sale_date")(_check_sale_date)


class SaleUpdate(StrictModel):
    """Edición de UNA venta (una línea): sustitución completa."""
    client_id: int
    contact_id: int | None = None
    sale_date: str
    product_id: int | None = None
    concept: str | None = Field(None, max_length=200)
    quantity: int | None = Field(None, ge=1, le=100_000)
    amount: StrictInt | StrictStr
    notes: str | None = Field(None, max_length=500)

    _blanks = field_validator("concept", "notes", mode="before")(_blank_to_none)
    _concept_case = field_validator("concept")(_capitalize)
    _date = field_validator("sale_date")(_check_sale_date)

    _amount_cents: int = PrivateAttr()

    @model_validator(mode="after")
    def _parse_amount(self):
        try:
            self._amount_cents = parse_money_cents(self.amount)
        except FormatError as error:
            raise ValueError(str(error)) from None
        return self

    @property
    def amount_cents(self) -> int:
        return self._amount_cents
