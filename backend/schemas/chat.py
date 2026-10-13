from typing import Annotated, Literal

from pydantic import BaseModel, Field

# Un mensaje de chat CRM cabe de sobra; /chat no es para pegar documentos
CHAT_MESSAGE_MAX_LENGTH = 2000

# Estricto: "1", 1.5 o true no son ids de conversación. Tope: el mayor
# INTEGER de SQLite (uno mayor haría fallar la consulta con un 500)
SQLITE_MAX_INTEGER = 2**63 - 1
ConversationId = Annotated[int, Field(strict=True, gt=0, le=SQLITE_MAX_INTEGER)]


class ChatRequest(BaseModel):
    # Vacío o solo espacios no es un 422: el chat responde con un error amable
    message: str = Field(max_length=CHAT_MESSAGE_MAX_LENGTH)
    # Sin id, el primer turno guardado crea una conversación nueva
    conversation_id: ConversationId | None = None


class ChatResponse(BaseModel):
    type: Literal["answer", "error"]
    content: str                      # Markdown
    # {"active_client": {id, name} | None, "active_contact": {id, name, client_id} | None}
    metadata: dict | None = None
    conversation_id: int | None = None
