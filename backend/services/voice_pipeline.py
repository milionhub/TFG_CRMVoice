"""
Audio de Voice V2 (POST /actions/interpret-audio), sin FastAPI:

- formatos y límites del audio aceptado (los valida api/audio.py);
- transcripción con Whisper local (carga perezosa en whisper_service).

El análisis del texto lo hace el Action Engine (services/actions). El
pipeline anterior de /process-audio (regex, confianza global) se retiró en H.5.2.
"""
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
