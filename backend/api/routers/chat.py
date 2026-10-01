"""Chat IA (/chat): asistente CRM de solo lectura con conversación persistente (G.3)."""
from fastapi import APIRouter, Depends, HTTPException, status

from api.deps import get_current_user
from schemas.chat import ChatRequest, ChatResponse
from services import chat as chat_service
from services.chat_store import ConversationNotFound

router = APIRouter(tags=["chat"])

# Misma respuesta si no existe o es de otro comercial: no revela cuál de los dos
CONVERSATION_NOT_FOUND = "Conversación no encontrada"


@router.post("/chat", response_model=ChatResponse)
def chat_endpoint(payload: ChatRequest, current_user: dict = Depends(get_current_user)):
    try:
        return chat_service.handle_chat_message(payload.message, current_user["user_id"], payload.conversation_id)
    except ConversationNotFound:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=CONVERSATION_NOT_FOUND) from None
