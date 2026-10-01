"""
Piezas comunes de las herramientas CRM: validación de argumentos, fechas y
la consulta de actividades (siempre del comercial indicado).

Fechas: activities.datetime_iso es texto ISO local sin zona
("YYYY-MM-DDTHH:MM:SS", a veces con milisegundos). Se compara como texto:
- los rangos de días son semiabiertos [inicio, fin) con límites
  "YYYY-MM-DD", válidos para cualquier hora o precisión de ese día;
- "ahora" es "YYYY-MM-DDTHH:MM:SS": pasada = datetime_iso < ahora,
  próxima = datetime_iso >= ahora.
"""
import sqlite3
from contextlib import closing
from datetime import date, datetime, timedelta

from db import get_connection


class ToolArgumentError(ValueError):
    """Argumento inválido para una herramienta (el orquestador lo devolverá al LLM)."""


# --- Argumentos -------------------------------------------------------

def validate_limit(limit, default: int, maximum: int) -> int:
    if limit is None:
        return default
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= maximum:
        raise ToolArgumentError(f"limit debe ser un entero entre 1 y {maximum}")
    return limit


def validate_id(value, name: str, *, optional: bool = False) -> int | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ToolArgumentError(f"{name} debe ser un entero positivo")
    return value


def parse_date(value, name: str) -> date | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ToolArgumentError(f"{name} debe ser una fecha YYYY-MM-DD")
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise ToolArgumentError(f"{name} debe ser una fecha YYYY-MM-DD") from None


def open_connection():
    """
    Conexión de solo consulta que se cierra siempre (with open_connection() as conn).
    PRAGMA query_only: SQLite rechaza cualquier escritura por esta conexión,
    así que las herramientas son de solo lectura también a nivel de BD.
    """
    conn = get_connection()
    conn.execute("PRAGMA query_only = ON")
    return closing(conn)


# --- Fechas -----------------------------------------------------------

def resolve_now(now: datetime | None) -> datetime:
    """Instante de referencia: inyectable (tests, orquestador); por defecto, el actual."""
    return (now or datetime.now()).replace(microsecond=0)


def iso_now(now: datetime) -> str:
    return now.strftime("%Y-%m-%dT%H:%M:%S")


def day_bound(day: date) -> str:
    return day.isoformat()


# Ámbitos temporales cerrados. No existe "pendiente": la tabla activities no
# tiene estado (pendiente/hecha/cancelada); solo se sabe si es pasada o próxima.
TEMPORAL_SCOPES = ("today", "tomorrow", "yesterday", "this_week", "next_week", "last_week", "upcoming", "past")


def scope_conditions(scope: str, now: datetime) -> list[tuple[str, str]]:
    """Condiciones SQL (fragmento fijo, parámetro) de un ámbito temporal."""
    today = now.date()
    monday = today - timedelta(days=today.weekday())

    if scope == "upcoming":
        return [("a.datetime_iso >= ?", iso_now(now))]
    if scope == "past":
        return [("a.datetime_iso < ?", iso_now(now))]

    start, end = {
        "today": (today, today + timedelta(days=1)),
        "tomorrow": (today + timedelta(days=1), today + timedelta(days=2)),
        "yesterday": (today - timedelta(days=1), today),
        "this_week": (monday, monday + timedelta(days=7)),        # lunes a domingo
        "next_week": (monday + timedelta(days=7), monday + timedelta(days=14)),
        "last_week": (monday - timedelta(days=7), monday),
    }[scope]
    return [("a.datetime_iso >= ?", day_bound(start)), ("a.datetime_iso < ?", day_bound(end))]


# --- Actividades --------------------------------------------------------

_ACTIVITY_SELECT = """
    SELECT a.id, a.datetime_iso, a.comentario,
           a.client_id, c.razon_social AS client_name,
           a.contact_id, ct.nombre AS contact_name,
           a.activity_type_id, at.accion AS activity_type
    FROM activities a
    LEFT JOIN clients c ON c.id = a.client_id
    LEFT JOIN contacts ct ON ct.id = a.contact_id
    LEFT JOIN activity_types at ON at.id = a.activity_type_id
"""

# Sin fecha al final en ambos sentidos; a igual fecha, por id
_ORDER = {
    "asc": " ORDER BY (a.datetime_iso IS NULL), a.datetime_iso ASC, a.id ASC",
    "desc": " ORDER BY (a.datetime_iso IS NULL), a.datetime_iso DESC, a.id DESC",
}


def _ref(ref_id, name):
    return {"id": ref_id, "name": name} if ref_id is not None else None


def id_in_condition(ids: list[int], column: str = "a.id") -> tuple[str, list[int]]:
    """Condición `column IN (?, ?, ...)`: solo se generan marcadores, nunca valores."""
    return f"{column} IN ({','.join('?' * len(ids))})", list(ids)


def _params(conditions) -> list:
    params = []
    for _, param in conditions:
        params.extend(param if isinstance(param, list) else [param])
    return params


def _activity_products(conn: sqlite3.Connection, activity_ids: list[int]) -> dict[int, list[dict]]:
    """Productos de varias actividades en una sola consulta."""
    if not activity_ids:
        return {}
    sql, params = id_in_condition(activity_ids, "ap.activity_id")
    rows = conn.execute(f"""
        SELECT ap.activity_id, ap.product_id, p.nombre
        FROM activity_products ap
        JOIN products p ON p.id = ap.product_id
        WHERE {sql}
        ORDER BY ap.activity_id, p.nombre, p.id
    """, params).fetchall()
    products = {}
    for r in rows:
        products.setdefault(r["activity_id"], []).append({"id": r["product_id"], "name": r["nombre"]})
    return products


def fetch_activities(conn: sqlite3.Connection, salesperson_id: int, conditions=(), *,
                     order: str = "desc", limit: int, now: datetime) -> tuple[list[dict], bool]:
    """
    Actividades del comercial que cumplen `conditions` ([(fragmento fijo,
    parámetro o lista de parámetros)]). Devuelve (actividades, has_more).
    El filtro por salesperson_id va siempre: no depende de quien llama.
    """
    where = ["a.salesperson_id = ?"] + [sql for sql, _ in conditions]
    params = [salesperson_id] + _params(conditions) + [limit + 1]
    rows = conn.execute(
        _ACTIVITY_SELECT + " WHERE " + " AND ".join(where) + _ORDER[order] + " LIMIT ?", params
    ).fetchall()

    has_more = len(rows) > limit
    rows = rows[:limit]
    products = _activity_products(conn, [r["id"] for r in rows])
    current = iso_now(now)

    return [
        {
            "id": r["id"],
            "datetime": r["datetime_iso"],
            "timing": None if r["datetime_iso"] is None else ("past" if r["datetime_iso"] < current else "upcoming"),
            "client": _ref(r["client_id"], r["client_name"]),
            "contact": _ref(r["contact_id"], r["contact_name"]),
            "activity_type": _ref(r["activity_type_id"], r["activity_type"]),
            "comment": r["comentario"],
            "products": products.get(r["id"], []),
        }
        for r in rows
    ], has_more


def activities_by_client(conn: sqlite3.Connection, salesperson_id: int, conditions=()) -> list[dict]:
    """
    Recuento por cliente de TODAS las actividades del comercial que cumplen
    `conditions` (sin el límite de la lista): responde a "¿con qué clientes…?".
    """
    where = ["a.salesperson_id = ?"] + [sql for sql, _ in conditions]
    rows = conn.execute(f"""
        SELECT a.client_id, c.razon_social, COUNT(*) AS total, MAX(a.datetime_iso) AS last_date
        FROM activities a
        LEFT JOIN clients c ON c.id = a.client_id
        WHERE {" AND ".join(where)}
        GROUP BY a.client_id
        ORDER BY total DESC, c.razon_social, a.client_id
    """, [salesperson_id] + _params(conditions)).fetchall()
    return [{"client": _ref(r["client_id"], r["razon_social"]), "activity_count": r["total"],
             "last_activity_datetime": r["last_date"]} for r in rows]


def activity_summary(conn: sqlite3.Connection, salesperson_id: int, now: datetime, *,
                     client_id: int | None = None, contact_id: int | None = None) -> dict:
    """Recuento, última pasada, próxima y tipos de las actividades DEL comercial (con un cliente o contacto)."""
    conditions = []
    if client_id is not None:
        conditions.append(("a.client_id = ?", client_id))
    if contact_id is not None:
        conditions.append(("a.contact_id = ?", contact_id))
    where = " AND ".join(["a.salesperson_id = ?"] + [sql for sql, _ in conditions])
    params = [salesperson_id] + _params(conditions)
    current = iso_now(now)

    counts = conn.execute(f"""
        SELECT COUNT(*) AS total,
               COALESCE(SUM(a.datetime_iso < ?), 0) AS past,
               COALESCE(SUM(a.datetime_iso >= ?), 0) AS upcoming
        FROM activities a WHERE {where}
    """, [current, current] + params).fetchone()

    by_type = conn.execute(f"""
        SELECT a.activity_type_id, at.accion, COUNT(*) AS total
        FROM activities a
        LEFT JOIN activity_types at ON at.id = a.activity_type_id
        WHERE {where}
        GROUP BY a.activity_type_id
        ORDER BY total DESC, at.accion, a.activity_type_id
    """, params).fetchall()

    last, _ = fetch_activities(conn, salesperson_id, conditions + [("a.datetime_iso < ?", current)],
                               order="desc", limit=1, now=now)
    upcoming, _ = fetch_activities(conn, salesperson_id, conditions + [("a.datetime_iso >= ?", current)],
                                   order="asc", limit=1, now=now)

    return {
        "scope": "salesperson",
        "total": counts["total"],
        "past": counts["past"],
        "upcoming": counts["upcoming"],
        "last_activity": last[0] if last else None,
        "next_activity": upcoming[0] if upcoming else None,
        "by_type": [
            {"activity_type": _ref(r["activity_type_id"], r["accion"]), "count": r["total"]}
            for r in by_type
        ],
    }
