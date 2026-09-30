from pydantic import BaseModel, Field

# Un mensaje de chat CRM cabe de sobra; /chat no es para pegar documentos
CHAT_MESSAGE_MAX_LENGTH = 2000


class ChatRequest(BaseModel):
    # Vacío o solo espacios no es un 422: el chat responde con un error amable
    message: str = Field(max_length=CHAT_MESSAGE_MAX_LENGTH)


class ChatResponse(BaseModel):
    type: str
    content: str
    metadata: dict | None = None


class PrepareMeetingRequest(BaseModel):
    client_id: int
