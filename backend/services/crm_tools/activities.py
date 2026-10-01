"""Consulta estructurada y búsqueda semántica de las actividades DEL comercial."""
import math
from datetime import datetime, timedelta

from services import semantic_search_service
from services.crm_tools._common import (
    TEMPORAL_SCOPES, ToolArgumentError, day_bound, fetch_activities, id_in_condition, open_connection,
    parse_date, resolve_now, scope_conditions, validate_id, validate_limit,
)

LIST_DEFAULT_LIMIT = 20
LIST_MAX_LIMIT = 50
SEARCH_DEFAULT_LIMIT = 5
SEARCH_MAX_LIMIT = 20
SEARCH_MAX_QUERY_LENGTH = 500

# La agenda (próximas, un día, una semana, un rango) se lee de la más
# cercana a la más lejana; lo pasado y el histórico, de la más reciente hacia atrás.
_ASCENDING_SCOPES = {"upcoming", "today", "tomorrow", "this_week", "next_week"}


def list_activities(salesperson_id: int, *, client_id: int | None = None, contact_id: int | None = None,
                    activity_type_id: int | None = None, date_from: str | None = None,
                    date_to: str | None = None, temporal_scope: str | None = None,
                    limit: int | None = None, now: datetime | None = None) -> dict:
    """
    Actividades del comercial que cumplen TODOS los filtros indicados.

    - temporal_scope: today | tomorrow | this_week (lunes a domingo) |
      next_week | upcoming (desde ahora) | past (antes de ahora).
    - date_from / date_to: días "YYYY-MM-DD", ambos INCLUSIVOS.
    - "Última actividad": temporal_scope="past", limit=1.

    Orden: ascendente (fecha, id) con ámbito de agenda o solo rango de
    fechas; descendente en "past" y sin filtro temporal.
    """
    client_id = validate_id(client_id, "client_id", optional=True)
    contact_id = validate_id(contact_id, "contact_id", optional=True)
    activity_type_id = validate_id(activity_type_id, "activity_type_id", optional=True)
    start = parse_date(date_from, "date_from")
    end = parse_date(date_to, "date_to")
    limit = validate_limit(limit, LIST_DEFAULT_LIMIT, LIST_MAX_LIMIT)
    if temporal_scope is not None and temporal_scope not in TEMPORAL_SCOPES:
        raise ToolArgumentError(f"temporal_scope debe ser uno de: {', '.join(TEMPORAL_SCOPES)}")
    if start and end and start > end:
        raise ToolArgumentError("date_from no puede ser posterior a date_to")
    now = resolve_now(now)

    conditions = []
    if client_id is not None:
        conditions.append(("a.client_id = ?", client_id))
    if contact_id is not None:
        conditions.append(("a.contact_id = ?", contact_id))
    if activity_type_id is not None:
        conditions.append(("a.activity_type_id = ?", activity_type_id))
    if start:
        conditions.append(("a.datetime_iso >= ?", day_bound(start)))
    if end:
        conditions.append(("a.datetime_iso < ?", day_bound(end + timedelta(days=1))))
    if temporal_scope:
        conditions += scope_conditions(temporal_scope, now)

    ascending = temporal_scope in _ASCENDING_SCOPES or (temporal_scope is None and (start or end))
    order = "asc" if ascending else "desc"

    with open_connection() as conn:
        activities, has_more = fetch_activities(conn, salesperson_id, conditions, order=order, limit=limit, now=now)

    return {
        "found": bool(activities),
        "filters": {
            "client_id": client_id, "contact_id": contact_id, "activity_type_id": activity_type_id,
            "date_from": date_from, "date_to": date_to, "temporal_scope": temporal_scope,
        },
        "now": now.isoformat(),
        "order": order,
        "count": len(activities),
        "has_more": has_more,
        "activities": activities,
    }


def search_activities(query: str, salesperson_id: int, *, client_id: int | None = None,
                      limit: int | None = None, now: datetime | None = None) -> dict:
    """
    Búsqueda semántica (text-embedding-3-small) entre las actividades del
    comercial, opcionalmente de un cliente. Lanza AIServiceError si falla OpenAI.
    score: similitud coseno con la consulta (mayor = más parecida).
    """
    if not isinstance(query, str) or not query.strip():
        raise ToolArgumentError("query no puede estar vacía")
    if len(query) > SEARCH_MAX_QUERY_LENGTH:
        raise ToolArgumentError(f"query admite como máximo {SEARCH_MAX_QUERY_LENGTH} caracteres")
    client_id = validate_id(client_id, "client_id", optional=True)
    limit = validate_limit(limit, SEARCH_DEFAULT_LIMIT, SEARCH_MAX_LIMIT)
    now = resolve_now(now)

    matches = semantic_search_service.semantic_search_activities(
        query, salesperson_id, client_id=client_id, top_k=limit
    )
    # Un embedding de norma cero da NaN en el coseno: no es un resultado
    scores = {m["activity_id"]: round(float(m["score"]), 4) for m in matches if math.isfinite(m["score"])}

    # Detalle con la consulta común, que vuelve a filtrar por comercial
    activities = []
    if scores:
        with open_connection() as conn:
            activities, _ = fetch_activities(conn, salesperson_id, [id_in_condition(list(scores))],
                                             limit=len(scores), now=now)

    results = [{"score": scores[a["id"]], "activity": a} for a in activities]
    results.sort(key=lambda r: (-r["score"], r["activity"]["id"]))

    return {
        "found": bool(results),
        "query": query,
        "client_id": client_id,
        "count": len(results),
        "results": results,
    }
