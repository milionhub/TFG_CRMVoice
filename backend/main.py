from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import re




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

def analyze_text(text: str) -> dict:
    """
    Simula un análisis 'inteligente' del texto.
    Extrae cliente, acción y fecha usando reglas simples.
    """
    lower = text.lower()
    cliente = None
    accion = None
    fecha = None

    # --- Cliente ---
    # Busca patrones tipo "cliente Carlos" o "con Carlos"
    match_cliente = re.search(
        r"cliente\s+([A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ]+(?:\s+[A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ]+)*)",
        text,
    )
    if match_cliente:
        cliente = match_cliente.group(1)
    else:
        match_con = re.search(
            r"con\s+([A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ]+)", text
        )
        if match_con:
            cliente = match_con.group(1)

    # --- Acción ---
    action_map = {
        "presupuesto": "Enviar presupuesto",
        "oferta": "Enviar oferta",
        "reunión": "Concertar reunión",
        "reunion": "Concertar reunión",
        "llamada": "Realizar llamada de seguimiento",
        "visita": "Registrar visita comercial",
    }

    for palabra, accion_descripcion in action_map.items():
        if palabra in lower:
            accion = accion_descripcion
            break

    # --- Fecha ---
    # Palabras tipo "hoy", "mañana", "martes", etc.
    fecha_keywords = [
        "hoy",
        "mañana",
        "lunes",
        "martes",
        "miércoles",
        "miercoles",
        "jueves",
        "viernes",
        "sábado",
        "sabado",
        "domingo",
    ]
    for fk in fecha_keywords:
        if fk in lower:
            fecha = fk
            break

    # Formato numérico tipo 10/12/2025
    match_fecha_num = re.search(r"\b(\d{1,2}/\d{1,2}/\d{2,4})\b", text)
    if match_fecha_num:
        fecha = match_fecha_num.group(1)

    return {
        "cliente": cliente,
        "accion": accion,
        "fecha": fecha,
        "comentario": text,
    }

@app.get("/")
def read_root():
    return {"message": "CRM Voice API funcionando 🚀"}


@app.get("/ping")
def ping():
    return {"status": "ok", "message": "pong"}

@app.post("/process-text")
def process_text(body: ProcessTextRequest):
    """
    Recibe un texto libre y devuelve una estructura
    con cliente, acción, fecha y comentario.
    """
    result = analyze_text(body.text)
    return result

# 🔴 NUEVO: endpoint para audio
@app.post("/process-audio")
async def process_audio(file: UploadFile = File(...)):
    """
    Recibe un archivo de audio y devuelve información básica
    para confirmar que ha llegado bien.
    """
    content = await file.read()
    size_kb = round(len(content) / 1024, 2)

    return {
        "filename": file.filename,
        "content_type": file.content_type,
        "size_kb": size_kb,
        "detail": "Audio recibido correctamente en el backend",
    }