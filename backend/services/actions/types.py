"""
Constantes del Action Engine (H.2). Los modelos (Interpretation, borradores,
DraftView, ediciones) están en schemas/actions.py; los errores son los de
dominio de services/writes (NotFound, ValidationFailed, Conflict, Gone,
ServiceUnavailable), que api/errors.py traduce a HTTP en un solo sitio.
"""
from datetime import timedelta

from schemas.actions import ACTION_TYPES, ActionType  # noqa: F401 (reexportados)

# Un borrador caduca 30 min después de crearse o de su última edición
DRAFT_TTL = timedelta(minutes=30)
# Los caducados se borran (perezosamente) un día después de caducar
PURGE_AFTER = timedelta(days=1)
# Fechas interpretadas a más de dos años de hoy (en cualquier sentido): no válidas
MAX_DATE_DISTANCE_DAYS = 730

MAX_PRODUCTS = 10
MAX_SALE_LINES = 5
