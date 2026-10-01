"""
Chat IA (/chat), G.3: asistente CRM de solo lectura con conversación persistente.

Por petición:
  1. chat_store.load_conversation: conversación propia + estado revalidado +
     historial acotado (lee y cierra la BD);
  2. chat_orchestrator.run: modelo ↔ herramientas del registro, SIN conexión
     abierta mientras se espera a OpenAI;
  3. chat_tools.derive_state: nuevo cliente/contacto activo a partir de la
     traza de herramientas (nunca del texto del modelo);
  4. chat_store.save_turn: turno + estado en una transacción corta.
"""
from datetime import datetime

from schemas.chat import ChatResponse
from services import chat_orchestrator, chat_store, chat_tools
from services.chat_store import ChatState

EMPTY_MESSAGE = "Escribe un mensaje para que pueda ayudarte."
AI_UNAVAILABLE_MESSAGE = "El asistente de IA no está disponible en este momento. Inténtalo de nuevo en unos minutos."
BUDGET_EXCEEDED_MESSAGE = (
    "No he podido completar la consulta a tiempo. Inténtalo de nuevo o haz una pregunta más concreta."
)
_ERROR_MESSAGES = {
    chat_orchestrator.AI_UNAVAILABLE: AI_UNAVAILABLE_MESSAGE,
    chat_orchestrator.BUDGET_EXCEEDED: BUDGET_EXCEEDED_MESSAGE,
}


def current_time() -> datetime:
    """Instante de la petición: el mismo para el contexto del modelo y todas las herramientas."""
    return datetime.now().replace(microsecond=0)


def _context_metadata(state: ChatState) -> dict:
    return {"active_client": state.client, "active_contact": state.contact}


def handle_chat_message(message: str, salesperson_id: int, conversation_id: int | None = None) -> ChatResponse:
    """Lanza chat_store.ConversationNotFound si conversation_id no es una conversación del comercial."""
    if not message.strip():
        return ChatResponse(type="error", content=EMPTY_MESSAGE)

    conversation = chat_store.load_conversation(conversation_id, salesperson_id)
    previous = conversation.state

    result = chat_orchestrator.run(message, conversation.history, previous, salesperson_id, now=current_time())

    if result.error:
        # Sin respuesta fiable el estado no cambia (aunque alguna herramienta fuera bien)
        response_type, content = "error", _ERROR_MESSAGES[result.error]
        client_id, contact_id = previous.client_id, previous.contact_id
    else:
        response_type, content = "answer", result.answer
        previous_contact = (previous.contact["id"], previous.contact["client_id"]) if previous.contact else None
        client_id, contact_id = chat_tools.derive_state(previous.client_id, previous_contact, result.outcomes)

    metadata = {"tools": [outcome.summary() for outcome in result.outcomes], "error": result.error}
    saved_id, state = chat_store.save_turn(conversation, salesperson_id, message, content, metadata,
                                           client_id, contact_id)

    return ChatResponse(type=response_type, content=content, metadata=_context_metadata(state),
                        conversation_id=saved_id)

