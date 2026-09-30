from pydantic import BaseModel


class ChatRequest(BaseModel):
    message: str


class ChatResponse(BaseModel):
    type: str
    content: str
    metadata: dict | None = None


class PrepareMeetingRequest(BaseModel):
    client_id: int
