"""
Resolución de clientes y contactos para el chat, con la lógica de la Fase F
(no hay un segundo resolvedor):
- nombres ya extraídos (client_name / contact_name, del modelo del chat o
  del intérprete de acciones): se resuelven tal cual;
- entity_resolver.resolve_client_and_contact aplica
  exact/fuzzy/ambiguous/unresolved y el contexto cliente↔contacto
  (conflict, inherited).

G.4 — coincidencia parcial (solo en esta herramienta; la voz no cambia):
si el resolvedor deja un nombre en "unresolved", se buscan clientes (razón
social o alias) o contactos (nombre) que contengan TODAS las palabras dichas
como palabras completas (sin tildes ni mayúsculas; palabras de menos de
PARTIAL_MIN_WORD_LENGTH letras se ignoran). Una sola coincidencia →
status "partial" (resuelto); varias → "ambiguous" (candidatos, sin elegir);
ninguna → sigue "unresolved". Ejemplo: "Costa" → "Diputacion Costa Verde".

Clientes y contactos son catálogo global: salesperson_id no filtra nada
aquí; se recibe para que todas las herramientas tengan el mismo contrato.
"""
from services.crm_tools._common import ToolArgumentError, id_in_condition, open_connection
from services.entity_resolver import normalize_text, resolve_client_and_contact

MAX_TEXT_LENGTH = 500
PARTIAL_MIN_WORD_LENGTH = 3


def _check_text(value, name):
    if value is not None and (not isinstance(value, str) or not value.strip() or len(value) > MAX_TEXT_LENGTH):
        raise ToolArgumentError(f"{name} debe ser un texto no vacío de hasta {MAX_TEXT_LENGTH} caracteres")


def _contact_info(conn, contact_ids: list[int]) -> dict[int, dict]:
    if not contact_ids:
        return {}
    sql, params = id_in_condition(sorted(set(contact_ids)), "ct.id")
    rows = conn.execute(f"""
        SELECT ct.id, ct.nombre, c.id AS client_id, c.razon_social
        FROM contacts ct JOIN clients c ON c.id = ct.client_id
        WHERE {sql}
    """, params).fetchall()
    return {r["id"]: {"name": r["nombre"], "client_id": r["client_id"], "client_name": r["razon_social"]}
            for r in rows}


# --- Coincidencia parcial por palabras completas (G.4) -------------------

def _words(mention: str) -> set[str]:
    return {w for w in normalize_text(mention).split() if len(w) >= PARTIAL_MIN_WORD_LENGTH}


def _contains_words(words: set[str], *names: str | None) -> bool:
    return any(words <= set(normalize_text(name).split()) for name in names if name)


def _partial_clients(conn, mention: str) -> list:
    words = _words(mention)
    if not words:
        return []
    rows = conn.execute("SELECT id, razon_social, alias FROM clients ORDER BY razon_social, id").fetchall()
    return [r for r in rows if _contains_words(words, r["razon_social"], r["alias"])]


def _partial_contacts(conn, mention: str, client_id: int | None) -> list:
    words = _words(mention)
    if not words:
        return []
    if client_id is None:
        rows = conn.execute("SELECT id, nombre, client_id FROM contacts ORDER BY nombre, id").fetchall()
    else:
        rows = conn.execute("SELECT id, nombre, client_id FROM contacts WHERE client_id = ? ORDER BY nombre, id",
                            (client_id,)).fetchall()
    return [r for r in rows if _contains_words(words, r["nombre"])]


def _with_partial_matches(resolution: dict, client_mention: str | None, contact_mention: str | None) -> dict:
    """Aplica la coincidencia parcial a lo que el resolvedor de la Fase F dejó sin resolver."""
    client, contact = resolution["client"], resolution["contact"]

    with open_connection() as conn:
        if client_mention and client["id"] is None and client["status"] in ("unresolved", "conflict"):
            matches = _partial_clients(conn, client_mention)
            if len(matches) == 1:
                # Se resuelve con el nombre completo para reutilizar el contexto
                # cliente↔contacto de la Fase F (contacto dentro del cliente, conflict)
                resolution = resolve_client_and_contact(matches[0]["razon_social"], contact_mention)
                client, contact = resolution["client"], resolution["contact"]
                client.update(status="partial", score=0.0,
                              candidates=[{"id": matches[0]["id"], "name": matches[0]["razon_social"], "score": 0.0}])
            elif matches:
                candidates = [{"id": r["id"], "name": r["razon_social"], "score": 0.0} for r in matches]
                if client["status"] == "conflict" and contact["id"] is not None:
                    # La Fase F ya resolvió el contacto fuera del cliente dicho. Solo
                    # deshace la ambigüedad si es de uno de los candidatos; si no,
                    # el conflicto se mantiene (no enseña ids ni cambia el estado).
                    owner = conn.execute("SELECT client_id FROM contacts WHERE id = ?",
                                         (contact["id"],)).fetchone()
                    compatible = [c for c in candidates if owner and c["id"] == owner["client_id"]]
                    if compatible:
                        client.update(id=compatible[0]["id"], status="partial", score=0.0, candidates=compatible)
                    else:
                        client.update(candidates=candidates)
                else:
                    client.update(status="ambiguous", candidates=candidates)

        if contact_mention and contact["id"] is None and contact["status"] == "unresolved":
            matches = _partial_contacts(conn, contact_mention, client["id"])
            if len(matches) == 1:
                match = matches[0]
                contact.update(id=match["id"], status="partial", score=0.0,
                               candidates=[{"id": match["id"], "name": match["nombre"], "score": 0.0}])
                if client["id"] is None and not client_mention:
                    # Sin cliente dicho, el contacto aporta el suyo (como "inherited" en la Fase F)
                    client.update(id=match["client_id"], status="inherited", origin="inherited", score=0.0)
                elif client["id"] is None and client["status"] == "unresolved":
                    # Se dijo un cliente que no existe y el contacto es de otro: conflicto (como en la Fase F)
                    client.update(status="conflict")
            elif matches:
                contact.update(status="ambiguous",
                               candidates=[{"id": r["id"], "name": r["nombre"], "score": 0.0} for r in matches])

    return resolution


def find_entities(salesperson_id: int, *, client_name: str | None = None,
                  contact_name: str | None = None) -> dict:
    """
    Cliente y contacto nombrados en client_name/contact_name (nombres ya
    extraídos). Nunca elige ante la ambigüedad: id solo con status exact,
    fuzzy, partial o inherited.
    """
    if client_name is None and contact_name is None:
        raise ToolArgumentError("indica client_name, contact_name o ambos")
    for value, name in ((client_name, "client_name"), (contact_name, "contact_name")):
        _check_text(value, name)
    client_mention, contact_mention = client_name, contact_name

    resolution = resolve_client_and_contact(client_mention, contact_mention)
    resolution = _with_partial_matches(resolution, client_mention, contact_mention)
    client, contact = resolution["client"], resolution["contact"]

    with open_connection() as conn:
        client_row = conn.execute("SELECT razon_social FROM clients WHERE id = ?",
                                  (client["id"],)).fetchone() if client["id"] else None
        contacts = _contact_info(conn, [c["id"] for c in contact["candidates"]]
                                 + ([contact["id"]] if contact["id"] else []))

    contact_resolved = contacts.get(contact["id"]) if contact["id"] else None

    return {
        "found": bool(client["id"] or contact["id"]),
        "client": {
            "id": client["id"],
            "name": client_row["razon_social"] if client_row else None,
            "mention": client_mention,
            "status": client["status"],
            "origin": client["origin"],
            "score": round(client["score"], 1),
            "candidates": [{"id": c["id"], "name": c["name"], "score": round(c["score"], 1)}
                           for c in client["candidates"]],
        },
        "contact": {
            "id": contact["id"],
            "name": contact_resolved["name"] if contact_resolved else None,
            "client_id": contact_resolved["client_id"] if contact_resolved else None,
            "mention": contact_mention,
            "status": contact["status"],
            "score": round(contact["score"], 1),
            "candidates": [
                {"id": c["id"], "name": c["name"], "score": round(c["score"], 1),
                 "client_id": contacts[c["id"]]["client_id"], "client_name": contacts[c["id"]]["client_name"]}
                for c in contact["candidates"]
            ],
        },
    }
