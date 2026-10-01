"""
Resolución de clientes y contactos para el chat, con la lógica de la Fase F
(no hay un segundo resolvedor):
- texto libre: text_analysis.analyze_text extrae las menciones igual que
  en /process-audio (regex + catálogo, sin fuzzy sobre todo el mensaje);
- nombres ya extraídos (client_name / contact_name): se resuelven tal cual;
- en ambos casos, entity_resolver.resolve_client_and_contact aplica
  exact/fuzzy/ambiguous/unresolved y el contexto cliente↔contacto
  (conflict, inherited).

Clientes y contactos son catálogo global: salesperson_id no filtra nada
aquí; se recibe para que todas las herramientas tengan el mismo contrato.
"""
from services.crm_tools._common import ToolArgumentError, id_in_condition, open_connection
from services.entity_resolver import resolve_client_and_contact
from services.text_analysis import analyze_text

MAX_TEXT_LENGTH = 500


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


def find_entities(text: str | None, salesperson_id: int, *, client_name: str | None = None,
                  contact_name: str | None = None) -> dict:
    """
    Cliente y contacto nombrados en `text`, o en client_name/contact_name
    (nombres ya extraídos; no se combinan con text). Nunca elige ante la
    ambigüedad: id solo con status exact, fuzzy o inherited.
    """
    structured = client_name is not None or contact_name is not None
    if structured and text is not None:
        raise ToolArgumentError("usa text o client_name/contact_name, no ambos")
    if not structured and text is None:
        raise ToolArgumentError("indica text, client_name o contact_name")
    for value, name in ((text, "text"), (client_name, "client_name"), (contact_name, "contact_name")):
        _check_text(value, name)

    if structured:
        client_mention, contact_mention = client_name, contact_name
    else:
        analysis = analyze_text(text)
        client_mention, contact_mention = analysis["cliente"], analysis["contacto"]

    resolution = resolve_client_and_contact(client_mention, contact_mention)
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
