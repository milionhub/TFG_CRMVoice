"""
ADAPTADOR TEMPORAL (H.2 -> se borra con la limpieza de Voice V2).

La app Flutter actual todavía envía los formatos anteriores a H.2:
- POST /activities desde NewActivityScreen: el resultado de /process-audio
  ("cliente_id", "contacto_id", "fecha_detectada", "products_detected", "texto"...);
- PUT /activities/{id} desde el calendario ("fecha", "client_id", "contact_id",
  "activity_type_id", "products": [{id, name}], sin estado ni comentario).

Aquí SOLO se traduce ese formato a ActivityIn (y a la "provenance" de
auditoría). No hay reglas de negocio: la validación, los duplicados y la
escritura son las de services/writes/activities.py, igual que para V2.
"""
from datetime import datetime

from pydantic import ValidationError

from core.formats import FormatError, iso_now, normalize_datetime
from schemas.crm import ActivityIn
from schemas.issues import issue
from services.writes import ValidationFailed, validation_failed

_LEGACY_CREATE_KEYS = {"cliente_id", "contacto_id", "fecha_detectada", "products_detected", "texto",
                       "cliente_detectado", "contacto_detectado", "accion_detectada", "overall_confidence"}
_LEGACY_UPDATE_KEYS = {"fecha", "products", "comentario"}
UPDATE_REQUIRED_FIELDS = ("fecha", "client_id", "contact_id", "activity_type_id", "products")


def is_legacy_create(data: dict) -> bool:
    return bool(_LEGACY_CREATE_KEYS & data.keys())


def is_legacy_update(data: dict) -> bool:
    return bool(_LEGACY_UPDATE_KEYS & data.keys())


def _fail(field: str, message: str, code: str = "invalid"):
    raise ValidationFailed([issue(code, field, message)], message)


def _build(fields: dict) -> ActivityIn:
    try:
        return ActivityIn.model_validate(fields)
    except ValidationError as error:
        raise validation_failed(error) from None


def _derived_status(datetime_iso: str, now: datetime) -> str:
    """El formato anterior no tiene estado: futura -> pendiente; si no, completada."""
    return "pending" if datetime_iso > iso_now(now) else "completed"


def translate_create(data: dict, now: datetime) -> tuple[ActivityIn, dict]:
    if not data.get("cliente_id"):
        _fail("client", "Cliente obligatorio", "missing")
    if data.get("activity_type_id") is None:
        # La pantalla actual muestra "detail" tal cual: mensaje claro, no el de Pydantic
        _fail("activity_type", "Tipo de actividad obligatorio", "missing")
    products = data.get("products_detected") or []
    if not isinstance(products, list) or any(not isinstance(p, dict) or p.get("product_id") is None
                                             for p in products):
        _fail("products", "Cada producto debe indicar su product_id")

    raw_date = data.get("fecha_detectada")
    try:
        datetime_iso = normalize_datetime(raw_date) if raw_date else iso_now(now)
    except FormatError as error:
        _fail("datetime", str(error))

    activity = _build({
        "client_id": data.get("cliente_id"),
        "contact_id": data.get("contacto_id"),
        "activity_type_id": data.get("activity_type_id"),
        "datetime": datetime_iso,
        "status": _derived_status(datetime_iso, now),
        "product_ids": [p["product_id"] for p in products],
        "comment": data.get("texto"),
    })
    provenance = {
        "transcription": data.get("texto"),
        "cliente_raw": data.get("cliente_detectado"),
        "contacto_raw": data.get("contacto_detectado"),
        "accion_raw": data.get("accion_detectada"),
        "resolution_status": data.get("resolution_status"),
        "resolution_confidence": data.get("overall_confidence"),
        "product_raw": {p["product_id"]: p.get("product_raw") for p in products},
        "product_confidence": {p["product_id"]: p.get("confidence") for p in products},
    }
    return activity, provenance


def translate_update(data: dict, current_status: str, current_comment: str | None,
                     now: datetime) -> tuple[ActivityIn, dict]:
    """
    PUT del calendario: sustitución completa de fecha, cliente, contacto, tipo
    y productos (B7: todos obligatorios). Sin "comentario" se conserva el
    actual; el estado se conserva, salvo una completada movida al futuro, que
    pasa a pendiente (completada + futura no es válido).
    """
    missing = [field for field in UPDATE_REQUIRED_FIELDS if field not in data]
    if missing:
        _fail(missing[0], "Faltan campos obligatorios: " + ", ".join(missing), "missing")
    if data.get("client_id") is None:
        _fail("client", "Cliente obligatorio", "missing")
    if data.get("activity_type_id") is None:
        _fail("activity_type", "Tipo de actividad obligatorio", "missing")
    products = data.get("products")
    if not isinstance(products, list) or any(not isinstance(p, dict) for p in products):
        _fail("products", "products debe ser una lista de productos")
    product_ids = []
    raw = {}
    for p in products:
        product_id = p.get("id") if p.get("id") is not None else p.get("product_id")
        if product_id is None:
            _fail("products", "Cada producto debe indicar su id")
        product_ids.append(product_id)
        raw[product_id] = p.get("name") or p.get("product_raw")
    if not data.get("fecha"):
        _fail("datetime", "Fecha obligatoria", "missing")
    try:
        datetime_iso = normalize_datetime(data["fecha"])
    except FormatError as error:
        _fail("datetime", str(error))

    status = current_status
    if status == "completed" and datetime_iso > iso_now(now):
        status = "pending"
    activity = _build({
        "client_id": data.get("client_id"),
        "contact_id": data.get("contact_id"),
        "activity_type_id": data.get("activity_type_id"),
        "datetime": datetime_iso,
        "status": status,
        "product_ids": product_ids,
        "comment": data.get("comentario", current_comment),
    })
    return activity, {"product_raw": raw, "product_confidence": {pid: 100 for pid in product_ids}}
