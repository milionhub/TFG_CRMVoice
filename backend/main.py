from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from db import get_connection, init_db
from whisper_service import transcribe_audio
from entity_resolver import resolve_client, resolve_activity_type, resolve_contact
from openai_service import generate_embedding, generate_meeting_summary
from context_service import build_context
from date_resolver import resolve_relative_date

import os
import re
import json
import numpy as np


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
    """
    Detecta empresa tras:
    - de García Sistemas
    - empresa García Sistemas
    """

    patterns = [
        r"(?:empresa|cliente)\s+([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ\s]+)",
        r"de\s+([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ\s]+?)(?:\s|$)",
    ]

    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            candidate = match.group(1).strip()

            # Limitar a máximo 3 palabras (evita capturar frases enteras)
            words = candidate.split()
            if len(words) <= 3:
                return normalize_name(candidate)

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


def detect_contact(text: str) -> str | None:
    """
    Detecta:
    - Laura Gómez
    - Laura
    - He hablado con Laura
    - Reunión con Laura Gómez
    """

    patterns = [
        # Laura Gómez
        r"(?:hablado con|reunión con|con)\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñ]+(?:\s+[A-ZÁÉÍÓÚÑ][a-záéíóúñ]+)?)",

        # Nombre completo aislado
        r"\b([A-ZÁÉÍÓÚÑ][a-záéíóúñ]+\s+[A-ZÁÉÍÓÚÑ][a-záéíóúñ]+)\b",

        # Solo primer nombre (pero NO si va seguido de 'de')
        r"\b([A-ZÁÉÍÓÚÑ][a-záéíóúñ]+)\b(?!\s+de)"
    ]

    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return match.group(1)

    return None






def analyze_text(text: str) -> dict:
    contacto = detect_contact(text)
    cliente = detect_cliente(text)

    return {
        "cliente": cliente,
        "contacto": contacto,
        "accion": detect_action(text),
        "fecha": resolve_relative_date(text),
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

    # -------------------------------
    # 1️⃣ RAW detectado
    # -------------------------------
    cliente_raw = analysis["cliente"]
    accion_raw = analysis["accion"]
    fecha_iso = analysis["fecha"]
    contacto_raw = analysis["contacto"]

    # -------------------------------
    # 2️⃣ Resolver entidades
    # -------------------------------
    client_id, client_confidence = resolve_client(cliente_raw)
    activity_type_id = resolve_activity_type(accion_raw)
    contact_id, contact_confidence = resolve_contact(contacto_raw, client_id)

    # -------------------------------
    # 3️⃣ Herencias inteligentes
    # -------------------------------

    # Contacto detectado pero no cliente → heredar cliente
    if contact_id and not client_id:
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT client_id FROM contacts WHERE id = ?", (contact_id,))
        row = cursor.fetchone()
        conn.close()

        if row:
            client_id = row["client_id"]
            client_confidence = contact_confidence

    # Cliente detectado pero no contacto → reintentar dentro cliente
    if client_id and contacto_raw and not contact_id:
        contact_id, contact_confidence = resolve_contact(contacto_raw, client_id)

    # Si tenemos contacto pero no cliente_raw → rellenarlo
    if contact_id and not cliente_raw:
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("""
            SELECT c.razon_social
            FROM clients c
            JOIN contacts ct ON ct.client_id = c.id
            WHERE ct.id = ?
        """, (contact_id,))
        row = cursor.fetchone()
        conn.close()

        if row:
            cliente_raw = row["razon_social"]

    # -------------------------------
    # 4️⃣ Confidence global
    # -------------------------------
    if client_id and contact_id:
        overall_confidence = min(client_confidence, contact_confidence)
    elif client_id:
        overall_confidence = client_confidence
    elif contact_id:
        overall_confidence = contact_confidence
    else:
        overall_confidence = 0

    if overall_confidence == 100:
        resolution_status = "exact"
    elif overall_confidence >= 80:
        resolution_status = "auto"
    elif overall_confidence > 0:
        resolution_status = "partial"
    else:
        resolution_status = "unresolved"

    # -------------------------------
    # 5️⃣ Generar embedding ANTES del INSERT
    # -------------------------------
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

    # -------------------------------
    # 6️⃣ Control de duplicados (ANTES de insertar)
    # -------------------------------
    if vector and client_id:
        from openai_service import is_duplicate_activity

        is_dup, similarity_score = is_duplicate_activity(
            vector,
            client_id,
            activity_type_id,
            fecha_iso
        )


        if is_dup:
            return {
                "error": "Actividad duplicada detectada",
                "similarity": similarity_score
            }

    # -------------------------------
    # 7️⃣ INSERT activity (solo si NO duplicada)
    # -------------------------------
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        INSERT INTO activities (
            fecha_iso,
            client_id,
            contact_id,
            activity_type_id,
            comentario,
            transcripcion,
            cliente_raw,
            contacto_raw,
            accion_raw,
            resolution_status,
            resolution_confidence
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        fecha_iso,
        client_id,
        contact_id,
        activity_type_id,
        analysis["comentario"],
        text_transcribed,
        cliente_raw,
        contacto_raw,
        accion_raw,
        resolution_status,
        overall_confidence
    ))

    activity_id = cursor.lastrowid

    # -------------------------------
    # 8️⃣ Guardar embedding
    # -------------------------------
    if vector:
        cursor.execute("""
            INSERT INTO activity_embeddings (
                activity_id,
                embedding_vector,
                embedding_model,
                content_type
            )
            VALUES (?, ?, ?, ?)
        """, (
            activity_id,
            str(vector),
            "text-embedding-3-small",
            "activity_full"
        ))

    conn.commit()
    conn.close()

    # -------------------------------
    # 9️⃣ Response
    # -------------------------------
    return {
        "texto": text_transcribed,
        "cliente_detectado": cliente_raw,
        "cliente_id": client_id,
        "contacto_detectado": contacto_raw,
        "contacto_id": contact_id,
        "accion_detectada": accion_raw,
        "activity_type_id": activity_type_id,
        "fecha_detectada": fecha_iso,
        "cliente_confidence": client_confidence,
        "contacto_confidence": contact_confidence,
        "overall_confidence": overall_confidence,
        "resolution_status": resolution_status,
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

class PrepareMeetingRequest(BaseModel):
    client_id: int


@app.post("/prepare-meeting")
def prepare_meeting(request: PrepareMeetingRequest):

    context_data = build_context(request.client_id)

    if not context_data:
        return {"error": "Cliente no encontrado"}

    try:
        summary = generate_meeting_summary(context_data)
    except Exception as e:
        return {"error": f"Error generando resumen: {str(e)}"}

    return {
        "client_id": request.client_id,
        "meeting_preparation": summary
    }
