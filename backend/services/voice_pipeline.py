"""
Pipeline de /process-audio (sin FastAPI):

- formatos y límites del audio aceptado;
- transcripción (Whisper local, carga perezosa en whisper_service);
- análisis del texto, resolución de entidades del CRM, fecha/hora,
  herencia cliente↔contacto y confianza global.

El router se encarga de la subida (UploadFile) y de traducir errores a HTTP.
"""
from date_resolver import resolve_time
from db import get_connection
from entity_resolver import resolve_client, resolve_activity_type, resolve_contact, resolve_products
from services.text_analysis import analyze_text
from whisper_service import transcribe_audio  # noqa: F401 (lo usa el router: voice_pipeline.transcribe_audio)

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


def analyze_transcription(text_transcribed: str) -> dict:
    """Del texto transcrito a la propuesta de actividad que revisa el usuario."""

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
    # 5️⃣ Obtener nombres oficiales
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
    # 6️⃣ Response
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
