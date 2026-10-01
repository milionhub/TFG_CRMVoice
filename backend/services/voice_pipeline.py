"""
Pipeline de /process-audio (sin FastAPI):

- formatos y límites del audio aceptado;
- transcripción (Whisper local, carga perezosa en whisper_service);
- análisis del texto, resolución de entidades del CRM, fecha/hora,
  herencia cliente↔contacto y confianza global.

Resolución contextual (F.2, en entity_resolver.resolve_client_and_contact,
compartida con las herramientas del chat):
- un cliente dicho pero no resuelto no se sustituye por el del contacto;
- solo se hereda el cliente de un contacto inequívoco si no se dijo ninguno;
- la ambigüedad y los conflictos se exponen (status, candidates, origen).

El router se encarga de la subida (UploadFile) y de traducir errores a HTTP.
"""
from services.date_resolver import resolve_time
from db import get_connection
from services.entity_resolver import resolve_activity_type, resolve_client_and_contact, resolve_products
from services.text_analysis import analyze_text
from services.whisper_service import transcribe_audio  # noqa: F401 (lo usa el router: voice_pipeline.transcribe_audio)

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


# -------------------------
# Confianza global
# -------------------------
# Pesos empresariales. Solo cuentan las entidades relevantes para la frase:
# el cliente y la acción siempre; el contacto si se nombra; los productos si
# se detecta alguno (no se puede distinguir "no mencionado" de "mencionado
# pero no reconocido": resolve_products solo devuelve los reconocidos).
WEIGHT_CLIENT = 0.4
WEIGHT_CONTACT = 0.3
WEIGHT_PRODUCT = 0.2
WEIGHT_ACTION = 0.1

RESOLVED = ("exact", "fuzzy")


def _candidates(candidates: list[dict]) -> list[dict]:
    return [{"id": c["id"], "nombre": c["name"], "score": round(c["score"], 1)} for c in candidates]


def _overall_confidence(client_score, contact_score, product_scores, action_score, contact_mentioned):
    parts = [(WEIGHT_CLIENT, client_score), (WEIGHT_ACTION, action_score)]
    if contact_mentioned:
        parts.append((WEIGHT_CONTACT, contact_score))
    if product_scores:
        parts.append((WEIGHT_PRODUCT, min(product_scores)))

    return round(sum(w * s for w, s in parts) / sum(w for w, _ in parts))


def _resolution_status(overall: int, statuses: list[str]) -> str:
    """
    Por umbrales de la confianza global, pero nunca mejor de lo que permiten
    las entidades nombradas: "exact" exige que todas sean exactas; con alguna
    fuzzy o heredada, como mucho "high"; con alguna ambigua, en conflicto o
    sin resolver, como mucho "medium".
    """
    if overall >= 95:
        status = "exact"
    elif overall >= 85:
        status = "high"
    elif overall >= 70:
        status = "medium"
    elif overall >= 50:
        status = "low"
    else:
        status = "unresolved"

    order = ["unresolved", "low", "medium", "high", "exact"]
    if any(s not in RESOLVED + ("inherited",) for s in statuses):
        cap = "medium"
    elif any(s != "exact" for s in statuses):
        cap = "high"
    else:
        cap = "exact"

    return min(status, cap, key=order.index)


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
    # 2️⃣ Resolver entidades (y 3️⃣ contacto ↔ cliente: entity_resolver)
    # -------------------------------
    resolution = resolve_client_and_contact(cliente_raw, contacto_raw)
    client, contact = resolution["client"], resolution["contact"]

    client_id = client["id"]
    cliente_raw = client["raw"]  # si se hereda, la razón social del contacto
    client_status = client["status"]
    client_confidence = client["score"]
    client_origin = client["origin"]
    client_candidates = _candidates(client["candidates"])

    contact_id = contact["id"]
    contact_status = contact["status"]
    contact_confidence = contact["score"]
    contact_candidates = _candidates(contact["candidates"])

    activity_type_id = resolve_activity_type(accion_raw)
    products_detected = resolve_products(text_transcribed)

    # -------------------------------
    # 4️⃣ Confidence global
    # -------------------------------
    client_score = client_confidence if client_id else 0
    contact_score = contact_confidence if contact_id else 0
    product_scores = [p["confidence"] for p in products_detected]
    action_score = 100 if activity_type_id else 0

    overall_confidence = _overall_confidence(
        client_score, contact_score, product_scores, action_score, contact_mentioned=bool(contacto_raw)
    )

    named = [client_status] + ([contact_status] if contacto_raw else []) + [
        "exact" if score >= 100 else "fuzzy" for score in product_scores
    ]
    resolution_status = _resolution_status(overall_confidence, named)

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

        # Metadatos de resolución (aditivos)
        "cliente_status": client_status,
        "cliente_origen": client_origin,
        "cliente_candidates": client_candidates,
        "contacto_status": contact_status,
        "contacto_candidates": contact_candidates,
    }
