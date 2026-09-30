from pydantic import BaseModel


class ProcessTextRequest(BaseModel):
    text: str
