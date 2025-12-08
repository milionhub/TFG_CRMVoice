from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

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


@app.get("/")
def read_root():
    return {"message": "CRM Voice API funcionando 🚀"}


@app.get("/ping")
def ping():
    return {"status": "ok", "message": "pong"}
