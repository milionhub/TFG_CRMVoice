from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from db import get_connection, init_db
from whisper_service import transcribe_audio
from entity_resolver import resolve_client, resolve_activity_type
from openai_service import generate_embedding
from context_service import build_context

import os
import re
import json
import numpy as np
from datetime import datetime, timedelta

class SemanticSearchRequest(BaseModel):
    query: str





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

    # RAW detectado por IA
    cliente_raw = analysis["cliente"]
    accion_raw = analysis["accion"]
    fecha_iso = analysis["fecha"]

    # Resolver entidades reales
    client_id, resolution_confidence = resolve_client(cliente_raw)
    activity_type_id = resolve_activity_type(accion_raw)

    # Determinar estado basado en confidence real
    if resolution_confidence == 100:
        resolution_status = "exact"
    elif resolution_confidence >= 80:
        resolution_status = "auto"
    elif resolution_confidence > 0:
        resolution_status = "partial"
    else:
        resolution_status = "unresolved"


    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute(
        """
        INSERT INTO activities (
            fecha_iso,
            client_id,
            activity_type_id,
            comentario,
            transcripcion,
            cliente_raw,
            accion_raw,
            resolution_status,
            resolution_confidence
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            fecha_iso,
            client_id,
            activity_type_id,
            analysis["comentario"],
            text_transcribed,
            cliente_raw,
            accion_raw,
            resolution_status,
            resolution_confidence
        ),
    )
     
    activity_id = cursor.lastrowid

    embedding_text = f"""
    Cliente: {cliente_raw}
    Acción: {accion_raw}
    Comentario: {analysis["comentario"]}
    Transcripción: {text_transcribed}
    """

    try:
        vector = generate_embedding(embedding_text)
    except Exception as e:
        print("Error generando embedding:", e)
        vector = None

    if vector:
        cursor.execute(
        """
            INSERT INTO activity_embeddings (
                activity_id,
                embedding_vector,
                embedding_model,
                content_type
            )
            VALUES (?, ?, ?, ?)
            """,
            (
                activity_id,
                str(vector),
                "text-embedding-3-small",
                "activity_full"
            ),
        )

    conn.commit()
    conn.close()

    return {
        "texto": text_transcribed,
        "cliente_detectado": cliente_raw,
        "accion_detectada": accion_raw,
        "fecha_detectada": fecha_iso,
        "client_id": client_id,
        "activity_type_id": activity_type_id,
        "resolution_status": resolution_status,
        "resolution_confidence": resolution_confidence,

    }



@app.get("/activities")
def get_activities():
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT 
            a.id,
            a.fecha_iso,
            a.comentario,
            a.resolution_status,
            c.razon_social AS cliente,
            at.accion AS accion
        FROM activities a
        LEFT JOIN clients c ON a.client_id = c.id
        LEFT JOIN activity_types at ON a.activity_type_id = at.id
        ORDER BY a.id DESC
    """)

    rows = cursor.fetchall()
    conn.close()

    return {
        "count": len(rows),
        "activities": [
            {
                "id": r["id"],
                "fecha": r["fecha_iso"],
                "cliente": r["cliente"],
                "accion": r["accion"],
                "comentario": r["comentario"],
                "resolution_status": r["resolution_status"]
            }
            for r in rows
        ],
    }

@app.post("/semantic-search")
def semantic_search(request: SemanticSearchRequest):

    query_text = request.query

    # 1️⃣ Generar embedding del query
    query_vector = generate_embedding(query_text)
    query_vector = np.array(query_vector)

    conn = get_connection()
    cursor = conn.cursor()

    # 2️⃣ Obtener todos los embeddings almacenados
    cursor.execute("""
        SELECT ae.activity_id, ae.embedding_vector, a.fecha_iso, a.cliente_raw, a.comentario
        FROM activity_embeddings ae
        JOIN activities a ON a.id = ae.activity_id
    """)

    rows = cursor.fetchall()

    results = []

    for row in rows:
        activity_id = row["activity_id"]
        stored_vector = np.array(json.loads(row["embedding_vector"]))

        # 3️⃣ Calcular similitud coseno
        similarity = np.dot(query_vector, stored_vector) / (
            np.linalg.norm(query_vector) * np.linalg.norm(stored_vector)
        )

        results.append({
            "id": activity_id,
            "fecha": row["fecha_iso"],
            "cliente": row["cliente_raw"],
            "comentario": row["comentario"],
            "score_similitud": float(similarity)
        })

    conn.close()

    # 4️⃣ Ordenar por similitud descendente
    results = sorted(results, key=lambda x: x["score_similitud"], reverse=True)

    # 5️⃣ Devolver top 3
    return results[:3]

@app.get("/client-context/{client_id}")
def get_client_context(client_id: int):
    return build_context(client_id)
