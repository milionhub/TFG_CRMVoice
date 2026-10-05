"""
Action Engine (H.2): de un texto (escrito o transcrito) a un borrador que el
usuario revisa y confirma. Independiente del transporte: lo usan la API de
/actions y, más adelante, la voz y el chat.

    texto -> interpreter (LLM, solo menciones) -> resolver (ids deterministas)
          -> drafts (borrador del comercial) -> executor.confirm (escritura)

El modelo nunca escribe ni genera ids de confianza, y nada interpretado se
guarda en el CRM hasta que el usuario confirma el borrador persistido.
Acciones soportadas: crear actividad, cliente, contacto o venta.
"""
from datetime import datetime

from services.actions import drafts, interpreter, resolver
from services.actions.executor import confirm
from services.openai_client import AIServiceError
from services.writes import ServiceUnavailable, current_time

AI_UNAVAILABLE_MESSAGE = "El asistente no está disponible ahora mismo. Inténtalo de nuevo en unos minutos."


def interpret_text(text: str, salesperson_id: int, *, source: str = "text", now: datetime | None = None) -> dict:
    """
    Interpreta y guarda un borrador (DraftView). No escribe nada de negocio.
    - OpenAI no disponible o respuesta inválida -> ServiceUnavailable (503);
    - acción no soportada -> ValidationFailed "unsupported" (422), sin borrador.
    """
    now = now or current_time()
    try:
        interpretation = interpreter.interpret(text, now)
    except AIServiceError:
        raise ServiceUnavailable("ai_unavailable", AI_UNAVAILABLE_MESSAGE) from None
    action_type, fields = resolver.resolve(interpretation, text, salesperson_id, now)
    return drafts.create(salesperson_id, action_type, source, text, interpretation, fields, now)


get_draft = drafts.get
edit_draft = drafts.edit
cancel_draft = drafts.cancel
confirm_draft = confirm

__all__ = ["interpret_text", "get_draft", "edit_draft", "cancel_draft", "confirm_draft", "AI_UNAVAILABLE_MESSAGE"]
