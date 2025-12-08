from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel



app = FastAPI(
    title="CRM Voice API",
    version="0.1.0",
    description="Backend base del TFG CRM Voice",
)

# Configuración CORS básica (luego la afinamos)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # en desarrollo permitimos todo
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class ProcessTextRequest(BaseModel):
    text: str


@app.get("/")
def read_root():
    return {"message": "CRM Voice API funcionando 🚀"}


@app.get("/ping")
def ping():
    return {"status": "ok", "message": "pong"}

@app.post("/process-text")
def process_text(body: ProcessTextRequest):
    text = body.text

    # Lógica simple por ahora: devolver el texto y su longitud
    return {
        "original_text": text,
        "length": len(text),
        "info": "Procesado correctamente en backend (simulación IA básica)",
    }
