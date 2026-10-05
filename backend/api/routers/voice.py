"""
Voz y texto (formato anterior a H.2, lo usa la app actual hasta Voice V2): análisis de un
dictado (/process-text) y de un audio (/process-audio). El Action Engine usa /actions.
"""
import logging

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool

from api.audio import read_audio_upload
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
    content, suffix = await read_audio_upload(file)

    try:
        # Whisper es CPU-bound: fuera del event loop
        text_transcribed = await run_in_threadpool(voice_pipeline.transcribe_audio, content, suffix)
    except Exception:
        logger.exception("Error transcribiendo audio")
        raise HTTPException(status_code=500, detail="No se pudo transcribir el audio")

    return voice_pipeline.analyze_transcription(text_transcribed)
