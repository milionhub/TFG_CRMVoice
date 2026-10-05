"""
Clientes (H.2): alta y edición. Son datos COMPARTIDOS por todos los
comerciales: created_by_salesperson_id es solo auditoría, nunca un filtro.

Duplicados (globales):
- bloquea: el nombre o el alias coinciden con el nombre o el alias de otro
  cliente, comparando sin tildes, mayúsculas, puntuación ni forma jurídica
  ("Rivera S.L." = "RIVERA, SL" = alias "Rivera");
- avisa (no bloquea): parecido >= SIMILAR_THRESHOLD con otro cliente. En el
  REST el alta se guarda y la respuesta trae el aviso en "warnings"; en un
  borrador es un issue "similar" no bloqueante.
No hay UNIQUE en la BD: esta normalización no se puede expresar en SQL.
"""
import sqlite3
from datetime import datetime

from rapidfuzz import fuzz

from core.formats import iso_now
from schemas.crm import ClientIn
from schemas.issues import Candidate, Issue, issue
from services.entity_resolver import normalize_client_name
from services.writes import NotFound, current_time, exists, raise_if_blocking, transaction

SIMILAR_THRESHOLD = 90


def _keys(*names) -> set[str]:
    return {key for key in (normalize_client_name(n) for n in names if n) if key}


def client_issues(conn: sqlite3.Connection, data: ClientIn, *, exclude_id: int | None = None) -> list[Issue]:
    """Validación de negocio de un cliente: grupo, duplicados (bloquean) y parecidos (avisan)."""
    issues = []
    if data.group_id is not None and not exists(conn, "client_groups", data.group_id):
        issues.append(issue("not_found", "group", "El grupo de cliente no existe."))

    new_keys = _keys(data.name, data.alias)
    name_key = normalize_client_name(data.name)
    rows = conn.execute("SELECT id, razon_social, alias FROM clients WHERE id IS NOT ?", (exclude_id,)).fetchall()
    similar = []
    for row in rows:
        existing_keys = _keys(row["razon_social"], row["alias"])
        if new_keys & existing_keys:
            return issues + [issue("duplicate", "client", f"Ya existe el cliente «{row['razon_social']}».",
                                   existing_id=row["id"],
                                   candidates=[Candidate(id=row["id"], label=row["razon_social"])])]
        score = max((fuzz.ratio(name_key, key) for key in existing_keys), default=0)
        if score >= SIMILAR_THRESHOLD:
            similar.append((score, row))
    if similar:
        similar.sort(key=lambda item: -item[0])
        names = ", ".join(f"«{row['razon_social']}»" for _, row in similar[:3])
        issues.append(issue("similar", "client", f"Se parece a un cliente que ya existe: {names}.",
                            blocking=False,
                            candidates=[Candidate(id=row["id"], label=row["razon_social"]) for _, row in similar[:3]]))
    return issues


def _row_out(conn, client_id: int) -> dict:
    row = conn.execute("""
        SELECT c.id, c.razon_social, c.alias, c.poblacion, c.provincia, c.group_id, g.name AS group_name,
               c.telefono, c.email, c.cif
        FROM clients c LEFT JOIN client_groups g ON g.id = c.group_id
        WHERE c.id = ?
    """, (client_id,)).fetchone()
    return {"id": row["id"], "name": row["razon_social"], "alias": row["alias"], "city": row["poblacion"],
            "province": row["provincia"], "group_id": row["group_id"], "group_name": row["group_name"],
            "phone": row["telefono"], "email": row["email"], "cif": row["cif"]}


def create_client(data: ClientIn, salesperson_id: int, *, conn: sqlite3.Connection | None = None,
                  now: datetime | None = None) -> dict:
    """Devuelve el cliente creado y sus avisos no bloqueantes ("warnings")."""
    stamp = iso_now(now or current_time())
    with transaction(conn) as c:
        issues = client_issues(c, data)
        raise_if_blocking(issues)
        client_id = c.execute("""
            INSERT INTO clients (razon_social, alias, poblacion, provincia, group_id, telefono, email, cif,
                                 created_by_salesperson_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (data.name, data.alias, data.city, data.province, data.group_id, data.phone, data.email, data.cif,
              salesperson_id, stamp, stamp)).lastrowid
        return {**_row_out(c, client_id), "warnings": [i.model_dump() for i in issues if not i.blocking]}


def update_client(client_id: int, data: ClientIn, salesperson_id: int, *, conn: sqlite3.Connection | None = None,
                  now: datetime | None = None) -> dict:
    """Sustitución completa de los campos editables. Cualquier comercial puede editar (CRM compartido)."""
    stamp = iso_now(now or current_time())
    with transaction(conn) as c:
        if not exists(c, "clients", client_id):
            raise NotFound("Cliente no encontrado")
        issues = client_issues(c, data, exclude_id=client_id)
        raise_if_blocking(issues)
        c.execute("""
            UPDATE clients SET razon_social = ?, alias = ?, poblacion = ?, provincia = ?, group_id = ?,
                               telefono = ?, email = ?, cif = ?, updated_at = ?
            WHERE id = ?
        """, (data.name, data.alias, data.city, data.province, data.group_id, data.phone, data.email, data.cif,
              stamp, client_id))
        return {**_row_out(c, client_id), "warnings": [i.model_dump() for i in issues if not i.blocking]}


def get_client(conn: sqlite3.Connection, client_id: int) -> dict:
    if not exists(conn, "clients", client_id):
        raise NotFound("Cliente no encontrado")
    return _row_out(conn, client_id)
