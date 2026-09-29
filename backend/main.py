from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI, UploadFile, File, Depends, HTTPException, status
from fastapi.concurrency import run_in_threadpool
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from datetime import datetime

from db import get_connection, init_db
from whisper_service import transcribe_audio
from entity_resolver import resolve_client, resolve_activity_type, resolve_contact, resolve_products
from openai_service import generate_embedding, generate_meeting_summary, format_billing_response, generate_client_summary, generate_account_analysis
from context_service import build_context, get_client_billing_summary
from date_resolver import resolve_relative_date, resolve_time
from semantic_search_service import semantic_search_activities
from jwt_utils import create_access_token, verify_token
from auth_utils import verify_password, hash_password
from chat_memory import set_last_client, get_last_client, set_pending_intent, get_pending_intent, clear_pending_intent
from client_detection_service import detect_client_from_message
from intent_service import detect_intent
from crm_insights_service import get_crm_insights
from opportunity_engine import detect_opportunities
from ai_router import analyze_user_message




import os
import re
import json
import logging
import numpy as np
from typing import Optional
from fastapi import Query
from google.oauth2 import id_token
from google.auth import exceptions as google_auth_exceptions
from google.auth.transport import requests as google_auth_requests


security = HTTPBearer()

logger = logging.getLogger("crmvoice")

# -------------------------
# AUDIO: límites y formatos aceptados
# -------------------------
MAX_AUDIO_BYTES = 10 * 1024 * 1024  # 10 MB

# La app envía el audio con MultipartFile.fromBytes sin contentType,
# así que suele llegar como application/octet-stream: el formato real
# se comprueba por la cabecera del fichero (magic bytes).
ALLOWED_AUDIO_CONTENT_TYPES = {
    "application/octet-stream",
    "video/webm",
    "video/mp4",
    "video/ogg",
}


def detect_audio_suffix(header: bytes) -> str | None:
    """
    Devuelve la extensión del formato de audio según su cabecera,
    o None si no parece un formato de audio conocido.
    """
    if header.startswith(b"RIFF") and header[8:12] == b"WAVE":
        return ".wav"
    if header.startswith(b"\x1a\x45\xdf\xa3"):
        return ".webm"
    if header.startswith(b"OggS"):
        return ".ogg"
    if header[4:8] == b"ftyp":
        return ".m4a"
    if header.startswith(b"fLaC"):
        return ".flac"
    if header.startswith(b"ID3"):
        return ".mp3"
    if header.startswith(b"#!AMR"):
        return ".amr"
    if header.startswith(b"caff"):
        return ".caf"
    if header.startswith(b"FORM") and header[8:12] in (b"AIFF", b"AIFC"):
        return ".aiff"
    if len(header) >= 2 and header[0] == 0xFF and (header[1] & 0xF6) == 0xF0:
        return ".aac"  # ADTS AAC
    if len(header) >= 2 and header[0] == 0xFF and (header[1] & 0xE0) == 0xE0:
        return ".mp3"  # frame MPEG sin cabecera ID3
    return None

class SemanticSearchRequest(BaseModel):
    query: str

class LoginRequest(BaseModel):
    email: str
    password: str

class RegisterRequest(BaseModel):
    nombre: str
    email: str
    password: str

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

def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(security)):

    token = credentials.credentials
    payload = verify_token(token)

    if payload is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token inválido o expirado"
        )

    user_id = payload.get("sub") or payload.get("user_id")

    if not user_id:
        raise HTTPException(
            status_code=401,
            detail="Token inválido"
        )

    return {
        "user_id": int(user_id),
        "email": payload.get("email")
    }

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


@app.post("/login")
def login(request: LoginRequest):

    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, nombre, email, password_hash
        FROM salespeople
        WHERE email = ?
    """, (request.email,))

    user = cursor.fetchone()
    conn.close()

    if not user:
        raise HTTPException(status_code=401, detail="Usuario no encontrado")

    user_id = user[0]
    nombre = user[1]
    user_email = user[2]
    stored_hash = user[3]

    # Usuarios creados con Google no tienen password_hash
    if not stored_hash:
        raise HTTPException(status_code=401, detail="Password incorrecto")

    try:
        password_ok = verify_password(request.password, stored_hash)
    except Exception:
        logger.exception("Hash de contraseña no válido para el usuario %s", user_id)
        password_ok = False

    if not password_ok:
        raise HTTPException(status_code=401, detail="Password incorrecto")

    token = create_access_token({
        "sub": str(user_id),
        "email": user_email
    })

    return {
        "access_token": token,
        "token_type": "bearer",
        "user": {
            "id": user_id,
            "nombre": nombre,
            "email": user_email
        }
    }

@app.post("/register")
def register(request: RegisterRequest):

    conn = get_connection()
    cursor = conn.cursor()

    # Verificar si email ya existe
    cursor.execute("""
        SELECT id FROM salespeople WHERE email = ?
    """, (request.email,))
    
    existing_user = cursor.fetchone()

    if existing_user:
        conn.close()
        raise HTTPException(
            status_code=400,
            detail="El email ya está registrado"
        )

    # Crear hash
    password_hash = hash_password(request.password)

    # Insertar usuario
    cursor.execute("""
        INSERT INTO salespeople (nombre, email, password_hash, created_at)
        VALUES (?, ?, ?, ?)
    """, (request.nombre, request.email, password_hash, datetime.utcnow()))

    conn.commit()

    user_id = cursor.lastrowid

    conn.close()

    # Crear token automáticamente
    token = create_access_token({
        "sub": str(user_id),
        "email": request.email
    })

    return {
        "access_token": token,
        "token_type": "bearer"
    }

@app.get("/me")
def get_me(current_user=Depends(get_current_user)):

    user_id = int(current_user.get("user_id")) or current_user.get("sub")
    user_id = int(user_id)  # Asegurar que es int

    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, nombre, email, created_at
        FROM salespeople
        WHERE id = ?
    """, (user_id,))

    user = cursor.fetchone()
    conn.close()

    if not user:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")

    return {
        "id": user[0],
        "nombre": user[1],
        "email": user[2],
        "created_at": user[3]
    }



@app.post("/auth/google")
def google_login(data: dict):

    # Client ID de la app web (público, no secreto): define la audience esperada
    google_client_id = os.getenv("GOOGLE_CLIENT_ID")

    if not google_client_id:
        logger.error("GOOGLE_CLIENT_ID no configurado: login con Google deshabilitado")
        raise HTTPException(status_code=503, detail="Login con Google no configurado")

    raw_id_token = data.get("idToken")

    if not raw_id_token or not isinstance(raw_id_token, str):
        raise HTTPException(status_code=400, detail="Missing token")

    # Verificación local del ID token: firma (claves públicas de Google),
    # iss, exp/iat y aud == nuestro Client ID
    try:
        idinfo = id_token.verify_oauth2_token(
            raw_id_token,
            google_auth_requests.Request(),
            audience=google_client_id,
            clock_skew_in_seconds=10,
        )
    except google_auth_exceptions.TransportError:
        logger.exception("Error obteniendo las claves públicas de Google")
        raise HTTPException(status_code=502, detail="No se pudo validar con Google")
    except (ValueError, google_auth_exceptions.GoogleAuthError):
        raise HTTPException(status_code=401, detail="Invalid Google token")

    # azp (authorized party), si viene, también debe ser nuestra app
    azp = idinfo.get("azp")
    if azp is not None and azp != google_client_id:
        raise HTTPException(status_code=401, detail="Invalid Google token")

    google_id = idinfo.get("sub")
    email = idinfo.get("email")
    name = idinfo.get("name", "")

    if not google_id or not email:
        raise HTTPException(status_code=401, detail="Invalid Google token")

    if idinfo.get("email_verified") is not True:
        raise HTTPException(status_code=401, detail="Email de Google no verificado")

    conn = get_connection()
    cursor = conn.cursor()

    try:

        cursor.execute(
            "SELECT * FROM salespeople WHERE google_id = ?",
            (google_id,)
        )

        user = cursor.fetchone()

        if not user:

            # ¿Ya existe una cuenta con ese email? → NO se enlaza automáticamente:
            # la cuenta tradicional debe entrar con su contraseña
            cursor.execute(
                "SELECT * FROM salespeople WHERE email = ?",
                (email,)
            )

            existing = cursor.fetchone()

            if existing:

                if existing["google_id"]:
                    raise HTTPException(
                        status_code=409,
                        detail="El email ya está asociado a otra cuenta de Google"
                    )

                raise HTTPException(
                    status_code=409,
                    detail="Este email ya tiene una cuenta en CRMVoice. Inicia sesión con tu contraseña."
                )

            # crear usuario si no existe
            cursor.execute(
                """
                INSERT INTO salespeople (nombre, email, google_id)
                VALUES (?, ?, ?)
                """,
                (name, email, google_id)
            )

            conn.commit()

            cursor.execute(
                "SELECT * FROM salespeople WHERE google_id = ?",
                (google_id,)
            )

            user = cursor.fetchone()

    finally:
        conn.close()

    jwt_token = create_access_token({
        "sub": str(user["id"]),
        "email": user["email"]
    })

    return {
        "access_token": jwt_token,
        "user": {
            "id": user["id"],
            "nombre": user["nombre"],
            "email": user["email"]
        }
    }

@app.post("/process-text")
def process_text(body: ProcessTextRequest, current_user: dict = Depends(get_current_user)):
    return analyze_text(body.text)

@app.post("/process-audio")
async def process_audio(file: UploadFile = File(...), current_user: dict = Depends(get_current_user)):

    content_type = (file.content_type or "application/octet-stream").split(";")[0].strip().lower()

    if not (content_type.startswith("audio/") or content_type in ALLOWED_AUDIO_CONTENT_TYPES):
        raise HTTPException(status_code=415, detail="Formato de audio no soportado")

    # Lectura acotada: nunca más de MAX_AUDIO_BYTES + 1 en memoria
    content = await file.read(MAX_AUDIO_BYTES + 1)

    if len(content) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="El audio supera el tamaño máximo (10 MB)")

    if not content:
        raise HTTPException(status_code=400, detail="Audio vacío")

    suffix = detect_audio_suffix(content[:16])

    if suffix is None:
        raise HTTPException(status_code=415, detail="Formato de audio no soportado")

    try:
        # Whisper es CPU-bound: fuera del event loop
        text_transcribed = await run_in_threadpool(transcribe_audio, content, suffix)
    except Exception:
        logger.exception("Error transcribiendo audio")
        raise HTTPException(status_code=500, detail="No se pudo transcribir el audio")

    analysis = analyze_text(text_transcribed)

    # -------------------------------
    # 1️⃣ RAW detectado
    # -------------------------------
    cliente_raw = analysis["cliente"]
    accion_raw = analysis["accion"]
    fecha_detectada = analysis["fecha"]
    hora_detectada = resolve_time(text_transcribed)

    if fecha_detectada:
        if hora_detectada:
            fecha_detectada = f"{fecha_detectada}T{hora_detectada}"
        else:
            fecha_detectada = f"{fecha_detectada}T00:00:00"
            
    contacto_raw = analysis["contacto"]

    # -------------------------------
    # 2️⃣ Resolver entidades
    # -------------------------------
    client_id, client_confidence = resolve_client(cliente_raw)
    activity_type_id = resolve_activity_type(accion_raw)
    contact_id, contact_confidence = resolve_contact(contacto_raw, client_id)
    products_detected = resolve_products(text_transcribed)
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
    # Pesos empresariales
    WEIGHT_CLIENT = 0.4
    WEIGHT_CONTACT = 0.3
    WEIGHT_PRODUCT = 0.2
    WEIGHT_ACTION = 0.1

    # Cliente
    client_score = client_confidence if client_id else 0

    # Contacto
    contact_score = contact_confidence if contact_id else 0

    # Producto (mínimo si hay varios)
    product_confidences = [p["confidence"] for p in products_detected]
    product_score = min(product_confidences) if product_confidences else 0

    # Acción (si existe activity_type_id la consideramos exacta)
    action_score = 100 if activity_type_id else 0

    # Score compuesto
    overall_confidence = (
        client_score * WEIGHT_CLIENT +
        contact_score * WEIGHT_CONTACT +
        product_score * WEIGHT_PRODUCT +
        action_score * WEIGHT_ACTION
    )

    overall_confidence = round(overall_confidence)

    if overall_confidence >= 95:
        resolution_status = "exact"
    elif overall_confidence >= 85:
        resolution_status = "high"
    elif overall_confidence >= 70:
        resolution_status = "medium"
    elif overall_confidence >= 50:
        resolution_status = "low"
    else:
        resolution_status = "unresolved"


    # -------------------------------
    # 9️⃣ Obtener nombres oficiales
    # -------------------------------

    cliente_nombre = None
    contacto_nombre = None

    if client_id:
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT razon_social FROM clients WHERE id = ?", (client_id,))
        row = cursor.fetchone()
        conn.close()

        if row:
            cliente_nombre = row["razon_social"]

    if contact_id:
        conn = get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT nombre FROM contacts WHERE id = ?", (contact_id,))
        row = cursor.fetchone()
        conn.close()

        if row:
            contacto_nombre = row["nombre"]

    # -------------------------------
    # 9️⃣ Response
    # -------------------------------
    return {
        "texto": text_transcribed,

        # Detectado por modelo
        "cliente_detectado": cliente_raw,
        "contacto_detectado": contacto_raw,

        # IDs reales
        "cliente_id": client_id,
        "contacto_id": contact_id,

        # Nombres oficiales BD
        "cliente_nombre": cliente_nombre,
        "contacto_nombre": contacto_nombre,

        "accion_detectada": accion_raw,
        "activity_type_id": activity_type_id,
        "fecha_detectada": fecha_detectada,

        "products_detected": products_detected,

        "cliente_confidence": client_confidence,
        "contacto_confidence": contact_confidence,
        "overall_confidence": overall_confidence,
        "resolution_status": resolution_status,
    }




@app.get("/activities")
def get_activities(
    client_id: Optional[int] = Query(None),
    action_id: Optional[int] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    current_user: dict = Depends(get_current_user),
):
    conn = get_connection()
    cursor = conn.cursor()

    base_query = """
        SELECT 
            a.id,
            a.datetime_iso,
            a.client_id,
            a.contact_id,
            a.activity_type_id,
            a.comentario,
            a.resolution_status,
            c.razon_social AS cliente,
            at.accion AS accion,
            ct.nombre AS contacto
        FROM activities a
        LEFT JOIN clients c ON a.client_id = c.id
        LEFT JOIN activity_types at ON a.activity_type_id = at.id
        LEFT JOIN contacts ct ON a.contact_id = ct.id
    """

    conditions = ["a.salesperson_id = ?"]
    params = [current_user["user_id"]]

    if client_id:
        conditions.append("a.client_id = ?")
        params.append(client_id)

    if action_id:
        conditions.append("a.activity_type_id = ?")
        params.append(action_id)

    if date_from:
        conditions.append("a.datetime_iso >= ?")
        params.append(date_from + "T00:00:00")

    if date_to:
        conditions.append("a.datetime_iso <= ?")
        params.append(date_to + "T23:59:59")

    if conditions:
        base_query += " WHERE " + " AND ".join(conditions)

    base_query += " ORDER BY a.datetime_iso DESC"

    cursor.execute(base_query, params)
    rows = cursor.fetchall()
    activities = []

    for r in rows:

        # 🔹 Obtener productos de la actividad
        cursor.execute("""
            SELECT product_id, product_raw
            FROM activity_products
            WHERE activity_id = ?
        """, (r["id"],))

        product_rows = cursor.fetchall()

        # product_id es necesario para que la edición conserve los productos
        products = [
            {
                "product_id": p["product_id"],
                "product_raw": p["product_raw"]
            }
            for p in product_rows
        ]

        activities.append({
            "id": r["id"],
            "fecha": r["datetime_iso"],

            # 🔹 IDs reales
            "client_id": r["client_id"],
            "contact_id": r["contact_id"],
            "activity_type_id": r["activity_type_id"],

            # 🔹 Datos visibles
            "cliente": r["cliente"],
            "contacto": r["contacto"],
            "accion": r["accion"],
            "comentario": r["comentario"],
            "resolution_status": r["resolution_status"],

            "products": products
        })

    conn.close()

    return {
        "count": len(activities),
        "activities": activities
    }

    


@app.post("/activities")
def create_activity(data: dict, current_user: dict = Depends(get_current_user)):
    # def (no async): FastAPI lo ejecuta en threadpool y la llamada
    # síncrona a OpenAI (embedding) no bloquea el event loop

    # -------------------------------
    # 1️⃣ Validación mínima
    # -------------------------------
    client_id = data.get("cliente_id")
    contact_id = data.get("contacto_id")
    activity_type_id = data.get("activity_type_id")

    if not client_id:
        return {"error": "Cliente obligatorio"}

    if not (contact_id or activity_type_id):
        return {"error": "Debe existir contacto o tipo de actividad"}

    # -------------------------------
    # 2️⃣ Generar embedding
    # -------------------------------
    embedding_text = f"""
    Cliente: {data.get("cliente_detectado")}
    Acción: {data.get("accion_detectada")}
    Comentario: {data.get("texto")}
    """

    try:
        vector = generate_embedding(embedding_text)
    except Exception as e:
        print("Error generando embedding:", e)
        vector = None

    # -------------------------------
    # 3️⃣ Control duplicados
    # -------------------------------
    if vector:
        from openai_service import is_duplicate_activity

        is_dup, similarity_score = is_duplicate_activity(
            vector,
            client_id,
            activity_type_id,
            data.get("fecha_detectada")
        )

        if is_dup:
            return {
                "error": "Actividad duplicada detectada",
                "similarity": similarity_score
            }


    fecha = data.get("fecha_detectada")

    if fecha:
        datetime_iso = fecha
    else:
        from datetime import datetime
        datetime_iso = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")

    # -------------------------------
    # 4️⃣ Insert activity
    # -------------------------------
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        INSERT INTO activities (
            datetime_iso,
            client_id,
            contact_id,
            activity_type_id,
            comentario,
            transcripcion,
            cliente_raw,
            contacto_raw,
            accion_raw,
            resolution_status,
            resolution_confidence,
            salesperson_id
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        datetime_iso,
        client_id,
        contact_id,
        activity_type_id,
        data.get("texto"),
        data.get("texto"),
        data.get("cliente_detectado"),
        data.get("contacto_detectado"),
        data.get("accion_detectada"),
        data.get("resolution_status"),
        data.get("overall_confidence"),
        current_user["user_id"],
    ))

    activity_id = cursor.lastrowid

    # -------------------------------
    # 6️⃣ Guardar productos
    # -------------------------------

    products = data.get("products_detected", [])

    for p in products:
        cursor.execute("""
            INSERT INTO activity_products (
                activity_id,
                product_id,
                product_raw,
                confidence_score
            )
            VALUES (?, ?, ?, ?)
        """, (
            activity_id,
            p["product_id"],
            p["product_raw"],
            p["confidence"]
        ))

    # -------------------------------
    # 5️⃣ Guardar embedding
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
            json.dumps(vector),
            "text-embedding-3-small",
            "activity_full"
        ))

    conn.commit()
    conn.close()

    return {
        "success": True,
        "activity_id": activity_id
    }

@app.get("/products")
def get_products(current_user: dict = Depends(get_current_user)):
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, nombre, precio
        FROM products
        ORDER BY nombre ASC
    """)

    rows = cursor.fetchall()
    conn.close()

    return {
        "products": [
            {
                "id": r["id"],
                "name": r["nombre"],
                "price": r["precio"]
            }
            for r in rows
        ]
    }

@app.post("/semantic-search")
def semantic_search(request: SemanticSearchRequest, current_user: dict = Depends(get_current_user)):

    query_text = request.query

    # 1️⃣ Generar embedding del query
    query_vector = generate_embedding(query_text)
    query_vector = np.array(query_vector)

    conn = get_connection()
    cursor = conn.cursor()

    # 2️⃣ Obtener todos los embeddings almacenados
    cursor.execute("""
        SELECT ae.activity_id, ae.embedding_vector, a.datetime_iso, a.cliente_raw, a.comentario
        FROM activity_embeddings ae
        JOIN activities a ON a.id = ae.activity_id
        WHERE a.salesperson_id = ?
    """, (current_user["user_id"],))

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
            "fecha": row["datetime_iso"],
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
def get_client_context(client_id: int, current_user: dict = Depends(get_current_user)):
    return build_context(client_id, current_user["user_id"])

class PrepareMeetingRequest(BaseModel):
    client_id: int

def prepare_meeting_by_client_id(client_id: int, salesperson_id: int):

    context_data = build_context(client_id, salesperson_id)

    if not context_data:
        return None, "Cliente no encontrado"

    try:
        summary = generate_meeting_summary(context_data)
    except Exception as e:
        return None, f"Error generando resumen: {str(e)}"

    return summary, None

@app.post("/prepare-meeting")
def prepare_meeting(request: PrepareMeetingRequest, current_user: dict = Depends(get_current_user)):

    context_data = build_context(request.client_id, current_user["user_id"])

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

@app.get("/clients")
def get_clients(current_user: dict = Depends(get_current_user)):
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, razon_social
        FROM clients
        ORDER BY razon_social ASC
    """)

    rows = cursor.fetchall()
    conn.close()

    return {
        "clients": [
            {
                "id": r["id"],
                "name": r["razon_social"]
            }
            for r in rows
        ]
    }

@app.get("/contacts")
def get_contacts(client_id: Optional[int] = Query(None), current_user: dict = Depends(get_current_user)):
    conn = get_connection()
    cursor = conn.cursor()

    if client_id:
        cursor.execute("""
            SELECT id, nombre
            FROM contacts
            WHERE client_id = ?
            ORDER BY nombre ASC
        """, (client_id,))
    else:
        cursor.execute("""
            SELECT id, nombre
            FROM contacts
            ORDER BY nombre ASC
        """)

    rows = cursor.fetchall()
    conn.close()

    return {
        "contacts": [
            {
                "id": r["id"],
                "name": r["nombre"]
            }
            for r in rows
        ]
    }

@app.get("/activity-types")
def get_activity_types(current_user: dict = Depends(get_current_user)):
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, accion
        FROM activity_types
        ORDER BY accion ASC
    """)

    rows = cursor.fetchall()
    conn.close()

    return {
        "activity_types": [
            {
                "id": r["id"],
                "name": r["accion"]
            }
            for r in rows
        ]
    }



class ChatRequest(BaseModel):
    message: str

class ChatResponse(BaseModel):
    type: str
    content: str
    metadata: dict | None = None


@app.post("/chat", response_model=ChatResponse)
def chat_endpoint(payload: ChatRequest, current_user: dict = Depends(get_current_user)  ):
    user_message = payload.message.lower()

    pending = get_pending_intent(current_user["user_id"])

    # 🔥 CASO 1 — hay intención pendiente → NO usar IA
    if pending:
        print("PENDING INTENT:", pending)

        if pending["waiting_for"] == "client":

            client_id, confidence = resolve_client(payload.message)

            if client_id:
                set_last_client(current_user["user_id"], client_id)

                # 🔥 usar intent original
                intent = pending["intent"]

                # limpiar estado
                clear_pending_intent(current_user["user_id"])

                print("RESOLVED CLIENT FROM FOLLOW-UP:", client_id)

                # 👇 IMPORTANTE: NO hay ai_client_name aquí
                ai_client_name = None

            else:
                return ChatResponse(
                    type="error",
                    content="No he podido identificar el cliente. ¿Puedes especificarlo mejor?"
                )

    # 🔥 CASO 2 — NO hay pending → usar IA
    else:

        analysis = analyze_user_message(payload.message)

        intent = analysis.get("intent")
        ai_client_name = analysis.get("client_name")
        confidence = analysis.get("confidence", 0)

        print("AI ANALYSIS:", analysis)

        # fallback
        if not intent or confidence < 60:
            intent = detect_intent(payload.message)

        # normalización
        intent_mapping = {
            "client_analysis": "client_summary"
        }

        if intent in intent_mapping:
            intent = intent_mapping[intent]

        # cliente desde IA
        if ai_client_name:
            client_id_ai, conf_ai = resolve_client(ai_client_name)

            print("AI CLIENT:", ai_client_name, "→", client_id_ai)

            if client_id_ai:
                set_last_client(current_user["user_id"], client_id_ai)

        # fallback cliente antiguo
        else:
            auto_client_id = detect_client_from_message(payload.message)

            if auto_client_id:
                set_last_client(current_user["user_id"], auto_client_id)

    if intent == "prepare_meeting":

        # 🔥 EXTRAER SOLO EL CLIENTE
        match = re.search(r"con (.+)", payload.message, re.IGNORECASE)

        if match:
            client_text = match.group(1).strip()
        else:
            client_text = payload.message

        print("CLIENT_TEXT LIMPIO:", client_text)

        client_id, confidence = resolve_client(client_text)

        print("CLIENT_ID:", client_id, "CONF:", confidence)

        if client_id:
            set_last_client(current_user["user_id"], client_id)
        else:
            client_id = get_last_client(current_user["user_id"])

        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="prepare_meeting",
                waiting_for="client"
            )

            return ChatResponse(
                type="prepare_meeting",
                content="¿Para qué cliente quieres preparar la reunión?"
            )

        summary, error = prepare_meeting_by_client_id(client_id, current_user["user_id"])

        if error:
            return ChatResponse(
                type="prepare_meeting",
                content=error
            )

        return ChatResponse(
            type="prepare_meeting",
            content=summary,
            metadata={
                "client_id": client_id,
                "suggested_actions": [
                    "client_summary",
                    "billing_query",
                    "semantic_search"
                ]
             }
        )

    # --- FACTURACIÓN ---
    if intent == "billing_query":

        # Intentamos extraer nombre después de "de" o "tiene"
        match = re.search(r"(de|tiene)\s+(.+)", payload.message, re.IGNORECASE)

        if match:
            client_text = match.group(2).strip()
        else:
            # Si no hay patrón claro, usamos todo el mensaje
            client_text = payload.message

        client_id, confidence = resolve_client(client_text)

        if client_id:
            set_last_client(current_user["user_id"], client_id)

        if not client_id:

            client_id = get_last_client(current_user["user_id"])

        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="billing_query",
                waiting_for="client"
            )

            return ChatResponse(
                type="billing_query",
                content="¿De qué cliente quieres consultar la facturación?"
            )

        billing = get_client_billing_summary(client_id)

        return ChatResponse(
            type="billing_summary",
            content="Resumen de facturación",
            metadata={
                "client_id": client_id,
                "billing": billing,
                "suggested_actions": [
                    "client_summary",
                    "prepare_meeting",
                    "semantic_search"
                ]
            }
        )


    # --- RESUMEN CLIENTE ---
    if intent == "client_summary":

        match = re.search(r"cliente (.+)", payload.message, re.IGNORECASE)

        if match:
            client_text = match.group(1).strip()

        if not match:

            set_pending_intent(
                current_user["user_id"],
                intent="client_summary",
                waiting_for="client"
            )

            return ChatResponse(
                type="client_summary",
                content="¿De qué cliente quieres el resumen?"
            )

        client_id, confidence = resolve_client(client_text)

        if client_id:
            set_last_client(current_user["user_id"], client_id)

        if not client_id:

            client_id = get_last_client(current_user["user_id"])

        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="client_summary",
                waiting_for="client"
            )

            return ChatResponse(
                type="client_summary",
                content=f"No he podido identificar el cliente '{client_text}'. ¿Puedes especificarlo mejor?"
            )

        context = build_context(client_id, current_user["user_id"])


        summary_text = generate_client_summary(context)

        short_status = summary_text.split("\n")[0] 

        # 🔹 separar oportunidades (ya lo tienes)
        opportunities = detect_opportunities(context)

        return ChatResponse(
            type="client_summary",
            content="Resumen cliente",
            metadata={
                "client_id": client_id,
                "client_name": context["client_name"],

                # 🔥 AQUÍ ESTÁ LA CLAVE
                "summary": {
                    "status": (
                        "Cliente activo"
                        if context["total_activities"] > 3
                        else "Cliente con baja actividad"
                    ),
                    "activity": f"{context['total_activities']} actividades registradas",
                    "opportunities": opportunities or []
                },

                "suggested_actions": [
                    "billing_query",
                    "prepare_meeting",
                    "semantic_search"
                ]
            }
        )

    
    # --- CONTEXTO CLIENTE ---
    if "contexto" in user_message:
        return ChatResponse(
            type="client_context",
            content="Buscando contexto del cliente..."
        )

    # --- BÚSQUEDA SEMÁNTICA ---
    if intent == "semantic_search":

        # Intentamos detectar cliente en el mensaje completo
        client_id, confidence = resolve_client(payload.message)

        if client_id:
            results = semantic_search_activities(payload.message, current_user["user_id"], client_id=client_id)
        else:
            results = semantic_search_activities(payload.message, current_user["user_id"])

        

        return ChatResponse(
            type="semantic_search",
            content=f"Resultados encontrados",
            metadata={
                "results": results,
                "suggested_actions": [
                    "client_summary",
                    "billing_query",
                    "prepare_meeting"
                ]
            }
        )


    # --- CRM INSIGHTS ---
    if intent == "crm_insights":

        insights = get_crm_insights()
        activity_insights = insights.get("activity_insights", [])
        activity_text = "\n".join(f"- {a}" for a in activity_insights)


        top_clients = "\n".join(
            f"- {c['razon_social']}"
            for c in insights["top_clients"]
        )

        inactive_clients = "\n".join(
            f"- {c['razon_social']}"
            for c in insights["inactive_clients"]
        )

        content = f"""
    📊 Insights del CRM

    Clientes con mayor facturación:
    {top_clients}

    Clientes sin actividad reciente:
    {inactive_clients}

    Actividad comercial detectada:
    {activity_text}
    """

        return ChatResponse(
            type="crm_insights",
            content=content,
            metadata={
                "suggested_actions": [
                    "client_summary",
                    "billing_query",
                    "semantic_search"
                ]
            }
        )


    # --- ANÁLISIS COMPLETO DE CLIENTE ---
    if intent == "client_analysis":

        client_id, confidence = resolve_client(payload.message)

        if client_id:
            set_last_client(current_user["user_id"], client_id)

        if not client_id:
            client_id = get_last_client(current_user["user_id"])
        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="client_analysis",
                waiting_for="client"
            )

            return ChatResponse(
                type="client_analysis",
                content="¿Qué cliente quieres analizar?"
            )

        context = build_context(client_id, current_user["user_id"])

        opportunities = detect_opportunities(context)

        analysis = generate_account_analysis(context)

        if opportunities:

            analysis += "\n\n📈 Insights automáticos detectados:\n"

            for o in opportunities:
                analysis += f"- {o}\n"

        return ChatResponse(
            type="client_analysis",
            content=analysis,
            metadata={
                "client_id": client_id,
                "suggested_actions": [
                    "billing_query",
                    "prepare_meeting",
                    "semantic_search"
                ]
        }
        )

    # --- OPORTUNIDADES CLIENTE ---
    if intent == "client_opportunities":

        client_id, confidence = resolve_client(payload.message)

        if client_id:
            set_last_client(current_user["user_id"], client_id)

        if not client_id:
            client_id = get_last_client(current_user["user_id"])

        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="client_opportunities",
                waiting_for="client"
            )

            return ChatResponse(
                type="client_opportunities",
                content="¿De qué cliente quieres ver oportunidades?"
            )
        context = build_context(client_id, current_user["user_id"])

        opportunities = detect_opportunities(context)

        if not opportunities:
            content = "No se han detectado oportunidades claras en este cliente."
        else:
            content = "📈 Oportunidades detectadas:\n\n"
            for o in opportunities:
                content += f"- {o}\n"

        return ChatResponse(
            type="client_opportunities",
            content=content,
            metadata={
                "client_id": client_id
            }
        )


    # --- DEFAULT ---
    return ChatResponse(
        type="error",
        content=f"No he entendido la petición. Prueba de nuevo."
    )


@app.delete("/activities/{activity_id}")
def delete_activity(activity_id: int, current_user: dict = Depends(get_current_user)):

    conn = get_connection()
    cursor = conn.cursor()

    try:

        # 🔹 Comprobar propiedad antes de tocar ningún dato relacionado
        cursor.execute("""
            SELECT id FROM activities
            WHERE id = ? AND salesperson_id = ?
        """, (activity_id, current_user["user_id"]))

        if cursor.fetchone() is None:
            raise HTTPException(status_code=404, detail="Actividad no encontrada")

        cursor.execute("DELETE FROM activity_products WHERE activity_id = ?", (activity_id,))
        cursor.execute("DELETE FROM activity_embeddings WHERE activity_id = ?", (activity_id,))
        cursor.execute("""
            DELETE FROM activities
            WHERE id = ?
            AND salesperson_id = ?
        """, (activity_id, current_user["user_id"]))

        # Solo confirmamos si realmente se ha eliminado la actividad
        if cursor.rowcount != 1:
            conn.rollback()
            raise HTTPException(status_code=404, detail="Actividad no encontrada")

        conn.commit()

    finally:
        conn.close()

    return {"success": True}

@app.put("/activities/{activity_id}")
def update_activity(activity_id: int, data: dict, current_user: dict = Depends(get_current_user)):

    conn = get_connection()
    cursor = conn.cursor()

    # 🔹 Comprobar propiedad y obtener comentario actual
    # (antes de borrar/insertar productos o actualizar nada)
    cursor.execute("""
        SELECT comentario FROM activities
        WHERE id = ? AND salesperson_id = ?
    """, (activity_id, current_user["user_id"]))

    row = cursor.fetchone()

    if row is None:
        conn.close()
        raise HTTPException(status_code=404, detail="Actividad no encontrada")

    comentario_actual = row["comentario"]

    comentario = data.get("comentario", comentario_actual)

    # 🔹 Si cambia el comentario, el embedding queda obsoleto.
    # Se genera ANTES de escribir nada (llamada de red fuera de la transacción).
    comentario_cambiado = comentario != comentario_actual
    new_vector = None

    if comentario_cambiado:

        cursor.execute("SELECT razon_social FROM clients WHERE id = ?", (data.get("client_id"),))
        client_row = cursor.fetchone()

        cursor.execute("SELECT accion FROM activity_types WHERE id = ?", (data.get("activity_type_id"),))
        type_row = cursor.fetchone()

        embedding_text = f"""
    Cliente: {client_row["razon_social"] if client_row else None}
    Acción: {type_row["accion"] if type_row else None}
    Comentario: {comentario}
    """

        try:
            new_vector = generate_embedding(embedding_text)
        except Exception:
            logger.exception("Error regenerando embedding de la actividad %s", activity_id)
            new_vector = None

    try:

        # 🔹 Update actividad
        cursor.execute("""
            UPDATE activities
            SET datetime_iso = ?,
                client_id = ?,
                contact_id = ?,
                activity_type_id = ?,
                comentario = ?
            WHERE id = ? AND salesperson_id = ?
        """, (
            data.get("fecha"),
            data.get("client_id"),
            data.get("contact_id"),
            data.get("activity_type_id"),
            comentario,
            activity_id,
            current_user["user_id"]
        ))

        # 🔹 Borrar productos anteriores
        cursor.execute("""
            DELETE FROM activity_products
            WHERE activity_id = ?
        """, (activity_id,))

        # 🔹 Insertar nuevos productos
        products = data.get("products", [])

        for p in products:

            # Se aceptan ambos formatos: {id, name} y {product_id, product_raw}
            product_id = p.get("id") if p.get("id") is not None else p.get("product_id")
            product_name = p.get("name") or p.get("product_raw")

            # 🔹 evitar crash si no hay id
            if product_id is None:
                continue

            cursor.execute("""
                INSERT INTO activity_products (
                    activity_id,
                    product_id,
                    product_raw,
                    confidence_score
                )
                VALUES (?, ?, ?, ?)
            """, (
                activity_id,
                product_id,
                product_name,
                1.0
            ))

        # 🔹 Mantener el embedding coherente con el comentario
        if comentario_cambiado:

            if new_vector:

                cursor.execute("""
                    UPDATE activity_embeddings
                    SET embedding_vector = ?, created_at = datetime('now')
                    WHERE activity_id = ?
                """, (json.dumps(new_vector), activity_id))

                if cursor.rowcount == 0:
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
                        json.dumps(new_vector),
                        "text-embedding-3-small",
                        "activity_full"
                    ))

            else:
                # Si OpenAI falla, mejor sin embedding que con uno obsoleto
                cursor.execute(
                    "DELETE FROM activity_embeddings WHERE activity_id = ?",
                    (activity_id,)
                )

        conn.commit()

        return {"success": True}

    except Exception:

        conn.rollback()
        logger.exception("Error actualizando la actividad %s", activity_id)

        return {
            "success": False,
            "error": "No se pudo actualizar la actividad"
        }

    finally:

        conn.close()