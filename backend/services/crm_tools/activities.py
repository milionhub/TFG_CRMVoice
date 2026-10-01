"""Consulta estructurada y búsqueda semántica de las actividades DEL comercial."""
import math
from datetime import datetime, timedelta

from services import semantic_search_service
from services.crm_tools._common import (
    TEMPORAL_SCOPES, ToolArgumentError, activities_by_client, day_bound, fetch_activities, id_in_condition,
    open_connection, parse_date, resolve_now, scope_conditions, validate_id, validate_limit,
)
from services.crm_tools.products import PRODUCT_NAME_MAX_LENGTH, resolve_product

LIST_DEFAULT_LIMIT = 20
LIST_MAX_LIMIT = 50
SEARCH_DEFAULT_LIMIT = 5
SEARCH_MAX_LIMIT = 20
SEARCH_MAX_QUERY_LENGTH = 500

# Un día, una semana, un rango o lo próximo se lee en orden cronológico;
# "past" y el histórico sin filtro, de la más reciente hacia atrás.
_ASCENDING_SCOPES = {"upcoming", "today", "tomorrow", "yesterday", "this_week", "next_week", "last_week"}


def list_activities(salesperson_id: int, *, client_id: int | None = None, contact_id: int | None = None,
                    activity_type_id: int | None = None, date_from: str | None = None,
                    date_to: str | None = None, temporal_scope: str | None = None,
                    product_name: str | None = None,
                    limit: int | None = None, now: datetime | None = None) -> dict:
    """
    Actividades del comercial que cumplen TODOS los filtros indicados.

    - temporal_scope: today | tomorrow | yesterday | this_week (lunes a
      domingo) | next_week | last_week | upcoming (desde ahora) | past
      (antes de ahora).
    - date_from / date_to: días "YYYY-MM-DD", ambos INCLUSIVOS.
    - product_name: nombre o alias de un producto del catálogo (nunca un id);
      lo resuelve resolve_product. Si es ambiguo o no existe no se adivina:
      found=false y product_filter explica el motivo. Si se resuelve,
      product_filter.by_client resume por cliente TODAS las actividades que
      cumplen los filtros (no solo las `limit` de la lista); con filtros de
      fecha o ámbito, total_without_date_filters cuenta las que hay sin ellos.
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
    if product_name is not None and (not isinstance(product_name, str) or not product_name.strip()
                                     or len(product_name) > PRODUCT_NAME_MAX_LENGTH):
        raise ToolArgumentError(f"product_name debe ser un texto no vacío de hasta {PRODUCT_NAME_MAX_LENGTH} caracteres")
    now = resolve_now(now)

    # Filtros de entidad y de tiempo por separado: con producto, el recuento sin
    # fechas evita que un periodo vacío parezca "nunca se habló de él"
    entity_conditions = []
    if client_id is not None:
        entity_conditions.append(("a.client_id = ?", client_id))
    if contact_id is not None:
        entity_conditions.append(("a.contact_id = ?", contact_id))
    if activity_type_id is not None:
        entity_conditions.append(("a.activity_type_id = ?", activity_type_id))
    time_conditions = []
    if start:
        time_conditions.append(("a.datetime_iso >= ?", day_bound(start)))
    if end:
        time_conditions.append(("a.datetime_iso < ?", day_bound(end + timedelta(days=1))))
    if temporal_scope:
        time_conditions += scope_conditions(temporal_scope, now)
    conditions = entity_conditions + time_conditions

    ascending = temporal_scope in _ASCENDING_SCOPES or (temporal_scope is None and (start or end))
    order = "asc" if ascending else "desc"

    product_filter = None
    activities, has_more = [], False
    with open_connection() as conn:
        if product_name is not None:
            resolution = resolve_product(conn, product_name)
            product_filter = {"query": product_name, "status": resolution["status"],
                              "product": resolution["product"]["name"] if resolution["product"] else None,
                              "candidates": resolution["candidates"]}
            if resolution["product"]:
                product_condition = ("a.id IN (SELECT ap.activity_id FROM activity_products ap WHERE ap.product_id = ?)",
                                     resolution["product"]["id"])
                conditions.append(product_condition)
                entity_conditions.append(product_condition)
        # Producto ambiguo o desconocido: no se consulta nada (no se adivina)
        if product_filter is None or product_filter["status"] == "resolved":
            activities, has_more = fetch_activities(conn, salesperson_id, conditions, order=order, limit=limit,
                                                    now=now)
            if product_filter is not None:
                product_filter["by_client"] = activities_by_client(conn, salesperson_id, conditions)
                if time_conditions:
                    # Las mismas actividades sin los filtros de fecha/ámbito (sigue siendo solo el comercial)
                    product_filter["total_without_date_filters"] = sum(
                        c["activity_count"] for c in activities_by_client(conn, salesperson_id, entity_conditions))

    return {
        "found": bool(activities),
        "filters": {
            "client_id": client_id, "contact_id": contact_id, "activity_type_id": activity_type_id,
            "date_from": date_from, "date_to": date_to, "temporal_scope": temporal_scope,
            "product_name": product_name,
        },
        "product_filter": product_filter,
        "now": now.isoformat(),
        "order": order,
        "count": len(activities),
        "has_more": has_more,
        "activities": activities,
    }


def search_activities(query: str, salesperson_id: int, *, client_id: int | None = None,
                      limit: int | None = None, now: datetime | None = None,
                      timeout: float | None = None) -> dict:
    """
    Búsqueda semántica (text-embedding-3-small) entre las actividades del
    comercial, opcionalmente de un cliente. Lanza AIServiceError si falla OpenAI.
    score: similitud coseno con la consulta (mayor = más parecida).
    timeout: segundos para el embedding en un solo intento (presupuesto del chat).
    """
    if not isinstance(query, str) or not query.strip():
        raise ToolArgumentError("query no puede estar vacía")
    if len(query) > SEARCH_MAX_QUERY_LENGTH:
        raise ToolArgumentError(f"query admite como máximo {SEARCH_MAX_QUERY_LENGTH} caracteres")
    client_id = validate_id(client_id, "client_id", optional=True)
    limit = validate_limit(limit, SEARCH_DEFAULT_LIMIT, SEARCH_MAX_LIMIT)
    now = resolve_now(now)

    matches = semantic_search_service.semantic_search_activities(
        query, salesperson_id, client_id=client_id, top_k=limit, timeout=timeout
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
