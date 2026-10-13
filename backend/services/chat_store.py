"""
Conversaciones persistentes del chat (G.3): solo lee y escribe las tablas
chat_conversations y chat_messages.

Transacciones cortas: load_conversation() lee y cierra; el orquestador
llama a OpenAI SIN ninguna conexión abierta; save_turn() guarda el turno
completo (mensaje del usuario + respuesta + estado) en una sola transacción.

El estado activo (cliente/contacto) es de confianza: lo decide el backend a
partir de resultados de herramientas, nunca del texto del asistente. Al
cargar se revalida contra el CRM y una referencia borrada se limpia.
"""
import json
from dataclasses import dataclass, field

from db import connection

HISTORY_MESSAGES = 8
HISTORY_ASSISTANT_CHARS = 1500


class ConversationNotFound(Exception):
    """La conversación no existe o es de otro comercial (el llamador no los distingue)."""


@dataclass(frozen=True)
class ChatState:
    """Estado activo con nombres del CRM. client: {id, name}; contact: {id, name, client_id}."""
    client: dict | None = None
    contact: dict | None = None

    @property
    def client_id(self) -> int | None:
        return self.client["id"] if self.client else None

    @property
    def contact_id(self) -> int | None:
        return self.contact["id"] if self.contact else None


@dataclass(frozen=True)
class Conversation:
    id: int | None                       # None: aún no existe (se crea al guardar el primer turno)
    state: ChatState = ChatState()
    history: list[dict] = field(default_factory=list)   # [{"role", "content"}], del más antiguo al más reciente


def _clip(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _resolve_state(conn, client_id: int | None, contact_id: int | None) -> ChatState:
    """
    Estado con datos actuales del CRM. Lo que ya no existe se descarta, y un
    contacto que no es del cliente activo también (el contacto implica su cliente).
    """
    client = None
    if client_id is not None:
        row = conn.execute("SELECT id, razon_social FROM clients WHERE id = ?", (client_id,)).fetchone()
        client = {"id": row["id"], "name": row["razon_social"]} if row else None

    contact = None
    if contact_id is not None:
        row = conn.execute("SELECT id, nombre, client_id FROM contacts WHERE id = ?", (contact_id,)).fetchone()
        if row and client and row["client_id"] == client["id"]:
            contact = {"id": row["id"], "name": row["nombre"], "client_id": row["client_id"]}

    return ChatState(client=client, contact=contact)


def _is_error_turn(metadata: str | None) -> bool:
    if not metadata:
        return False
    try:
        return bool(json.loads(metadata).get("error"))
    except (ValueError, AttributeError):
        return True  # metadata ilegible: no se usa como contexto


def _history(conn, conversation_id: int) -> list[dict]:
    """Últimos HISTORY_MESSAGES mensajes sin las respuestas de error (no son conversación útil)."""
    rows = conn.execute("""
        SELECT role, content, metadata FROM chat_messages
        WHERE conversation_id = ?
        ORDER BY id DESC
        LIMIT ?
    """, (conversation_id, HISTORY_MESSAGES * 2)).fetchall()

    messages = [
        {"role": r["role"],
         "content": _clip(r["content"], HISTORY_ASSISTANT_CHARS) if r["role"] == "assistant" else r["content"]}
        for r in rows
        if not (r["role"] == "assistant" and _is_error_turn(r["metadata"]))
    ][:HISTORY_MESSAGES]
    messages.reverse()
    return messages


def load_conversation(conversation_id: int | None, salesperson_id: int) -> Conversation:
    """
    Conversación del comercial, con su estado revalidado e historial acotado.
    Sin id: conversación nueva (todavía sin fila). Lanza ConversationNotFound
    si no existe o no es suya: una sola consulta con ambos ids, sin oráculo.
    """
    if conversation_id is None:
        return Conversation(id=None)

    with connection() as conn:
        row = conn.execute("""
            SELECT id, active_client_id, active_contact_id FROM chat_conversations
            WHERE id = ? AND salesperson_id = ?
        """, (conversation_id, salesperson_id)).fetchone()
        if row is None:
            raise ConversationNotFound()

        state = _resolve_state(conn, row["active_client_id"], row["active_contact_id"])
        if (state.client_id, state.contact_id) != (row["active_client_id"], row["active_contact_id"]):
            # Referencia borrada o incoherente: se limpia también en la BD
            conn.execute("""
                UPDATE chat_conversations SET active_client_id = ?, active_contact_id = ?
                WHERE id = ?
            """, (state.client_id, state.contact_id, row["id"]))

        return Conversation(id=row["id"], state=state, history=_history(conn, row["id"]))


def save_turn(conversation: Conversation, salesperson_id: int, user_text: str, assistant_text: str,
              metadata: dict, client_id: int | None, contact_id: int | None) -> tuple[int, ChatState]:
    """
    Guarda el turno y el nuevo estado en una transacción. Crea la
    conversación si es nueva. Devuelve (conversation_id, estado guardado).
    """
    with connection() as conn:
        # Revalidación dentro de la transacción: algo pudo borrarse mientras respondía OpenAI
        state = _resolve_state(conn, client_id, contact_id)

        if conversation.id is None:
            conversation_id = conn.execute("""
                INSERT INTO chat_conversations (salesperson_id, active_client_id, active_contact_id)
                VALUES (?, ?, ?)
            """, (salesperson_id, state.client_id, state.contact_id)).lastrowid
        else:
            conversation_id = conversation.id
            updated = conn.execute("""
                UPDATE chat_conversations
                SET active_client_id = ?, active_contact_id = ?, updated_at = datetime('now')
                WHERE id = ? AND salesperson_id = ?
            """, (state.client_id, state.contact_id, conversation_id, salesperson_id)).rowcount
            if updated == 0:
                raise ConversationNotFound()

        conn.executemany("""
            INSERT INTO chat_messages (conversation_id, role, content, metadata) VALUES (?, ?, ?, ?)
        """, [
            (conversation_id, "user", user_text, None),
            (conversation_id, "assistant", assistant_text, json.dumps(metadata, ensure_ascii=False)),
        ])

    return conversation_id, state
