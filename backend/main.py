from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from db import get_connection, init_db
from whisper_service import transcribe_audio
import re
from datetime import datetime, timedelta


app = FastAPI(
    title="CRM Voice API",
    version="0.3.0",
    description="Backend del TFG CRM Voice",
)

init_db()

# -------------------------
# CORS
# -------------------------
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# -------------------------
# MODELOS
# -------------------------
class ProcessTextRequest(BaseModel):
    text: str


# =========================
# UTILIDADES IA
# =========================

def normalize_name(name: str) -> str:
    return " ".join(word.capitalize() for word in name.split())


def detect_cliente(text: str) -> str | None:
    patterns = [
        r"cliente\s+([A-Za-zÁÉÍÓÚÑáéíóúñ]+(?:\s+[A-Za-zÁÉÍÓÚÑáéíóúñ]+){0,2})",
        r"con\s+([A-Za-zÁÉÍÓÚÑáéíóúñ]+(?:\s+(?:corp|sl|s\.l\.|industries|group|company))?)",
        r"he hablado con\s+([A-Za-zÁÉÍÓÚÑáéíóúñ]+)",
        r"hablé con\s+([A-Za-zÁÉÍÓÚÑáéíóúñ]+)",
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return normalize_name(match.group(1))

    return None


def detect_action(text: str) -> str | None:
    rules = [
        (r"enviar.*presupuesto|presupuesto", "Enviar presupuesto"),
        (r"enviar.*oferta|oferta", "Enviar oferta"),
        (r"concertar.*reunión|reunión|reunion", "Concertar reunión"),
        (r"visita", "Registrar visita comercial"),
        (r"llamada|llamar", "Realizar llamada de seguimiento"),
    ]

    lower = text.lower()
    for pattern, action in rules:
        if re.search(pattern, lower):
            return action

    return None


def normalize_fecha(text: str) -> str | None:
    """
    Convierte fechas relativas a formato ISO YYYY-MM-DD
    """
    today = datetime.today()
    lower = text.lower()

    if "hoy" in lower:
        return today.strftime("%Y-%m-%d")

    if "mañana" in lower:
        return (today + timedelta(days=1)).strftime("%Y-%m-%d")

    weekdays = {
        "lunes": 0,
        "martes": 1,
        "miércoles": 2,
        "miercoles": 2,
        "jueves": 3,
        "viernes": 4,
        "sábado": 5,
        "sabado": 5,
        "domingo": 6,
    }

    for day, weekday in weekdays.items():
        if day in lower:
            days_ahead = (weekday - today.weekday() + 7) % 7
            days_ahead = 7 if days_ahead == 0 else days_ahead
            return (today + timedelta(days=days_ahead)).strftime("%Y-%m-%d")

    # Fecha explícita 10/12/2025
    match = re.search(r"\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b", text)
    if match:
        day, month, year = match.groups()
        year = "20" + year if len(year) == 2 else year
        try:
            return datetime(int(year), int(month), int(day)).strftime("%Y-%m-%d")
        except ValueError:
            return None

    return None


def analyze_text(text: str) -> dict:
    return {
        "cliente": detect_cliente(text),
        "accion": detect_action(text),
        "fecha": normalize_fecha(text),
        "comentario": text,
    }


# =========================
# ENDPOINTS
# =========================

@app.get("/")
def read_root():
    return {"message": "CRM Voice API funcionando 🚀"}


@app.get("/ping")
def ping():
    return {"status": "ok"}


@app.post("/process-text")
def process_text(body: ProcessTextRequest):
    return analyze_text(body.text)


@app.post("/process-audio")
async def process_audio(file: UploadFile = File(...)):
    content = await file.read()

    try:
        text_transcribed = transcribe_audio(content)
    except Exception as e:
        return {"error": str(e)}

    analysis = analyze_text(text_transcribed)

    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute(
        """
        INSERT INTO activities (cliente, accion, fecha, comentario, transcripcion)
        VALUES (?, ?, ?, ?, ?)
        """,
        (
            analysis["cliente"],
            analysis["accion"],
            analysis["fecha"],
            analysis["comentario"],
            text_transcribed,
        ),
    )

    conn.commit()
    conn.close()

    return {
        "texto": text_transcribed,
        **analysis,
        "detail": "Audio procesado y fecha normalizada",
    }


@app.get("/activities")
def get_activities():
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, cliente, accion, fecha, comentario
        FROM activities
        ORDER BY id DESC
    """)

    rows = cursor.fetchall()
    conn.close()

    return {
        "count": len(rows),
        "activities": [
            {
                "id": r[0],
                "cliente": r[1],
                "accion": r[2],
                "fecha": r[3],
                "comentario": r[4],
            }
            for r in rows
        ],
    }
