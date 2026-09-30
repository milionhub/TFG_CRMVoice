"""Chat IA (/chat) y preparación de reuniones (/prepare-meeting)."""
from fastapi import APIRouter, Depends

from api.deps import get_current_user
from schemas.chat import ChatRequest, ChatResponse, PrepareMeetingRequest
from services import chat as chat_service

router = APIRouter(tags=["chat"])


@router.post("/prepare-meeting")
def prepare_meeting(request: PrepareMeetingRequest, current_user: dict = Depends(get_current_user)):
    return chat_service.prepare_meeting(request.client_id, current_user["user_id"])


@router.post("/chat", response_model=ChatResponse)
def chat_endpoint(payload: ChatRequest, current_user: dict = Depends(get_current_user)):
    return chat_service.handle_chat_message(payload.message, current_user["user_id"])
