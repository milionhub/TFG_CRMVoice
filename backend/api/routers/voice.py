"""Voz y texto: análisis de un dictado (/process-text) y de un audio (/process-audio)."""
import logging

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool

from api.deps import get_current_user
from schemas.voice import ProcessTextRequest
from services import text_analysis, voice_pipeline

logger = logging.getLogger("crmvoice")

router = APIRouter(tags=["voice"])


@router.post("/process-text")
def process_text(body: ProcessTextRequest, current_user: dict = Depends(get_current_user)):
    return text_analysis.analyze_text(body.text)


@router.post("/process-audio")
async def process_audio(file: UploadFile = File(...), current_user: dict = Depends(get_current_user)):

    content_type = (file.content_type or "application/octet-stream").split(";")[0].strip().lower()

    if not (content_type.startswith("audio/") or content_type in voice_pipeline.ALLOWED_AUDIO_CONTENT_TYPES):
        raise HTTPException(status_code=415, detail="Formato de audio no soportado")

    # Lectura acotada: nunca más de MAX_AUDIO_BYTES + 1 en memoria
    content = await file.read(voice_pipeline.MAX_AUDIO_BYTES + 1)

    if len(content) > voice_pipeline.MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="El audio supera el tamaño máximo (10 MB)")

    if not content:
        raise HTTPException(status_code=400, detail="Audio vacío")

    suffix = voice_pipeline.detect_audio_suffix(content[:16])

    if suffix is None:
        raise HTTPException(status_code=415, detail="Formato de audio no soportado")

    try:
        # Whisper es CPU-bound: fuera del event loop
        text_transcribed = await run_in_threadpool(voice_pipeline.transcribe_audio, content, suffix)
    except Exception:
        logger.exception("Error transcribiendo audio")
        raise HTTPException(status_code=500, detail="No se pudo transcribir el audio")

    return voice_pipeline.analyze_transcription(text_transcribed)
