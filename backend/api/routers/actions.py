"""
Action Engine (H.2): interpretar un texto o un audio en un BORRADOR, editarlo,
confirmarlo o cancelarlo. Nada de negocio se escribe hasta /confirm.

Todas las rutas exigen sesión y solo ven los borradores del comercial
(el de otro responde igual que uno inexistente: 404). Los errores de dominio
los traduce api/errors.py (404, 409, 410, 422, 503) con mensajes seguros.
"""
import logging
import re

from fastapi import APIRouter, Depends, File, UploadFile, status
from fastapi.concurrency import run_in_threadpool

from api.audio import read_audio_upload
from api.deps import get_current_user
from schemas.actions import ConfirmRequest, DraftPatch, InterpretTextRequest, MAX_SOURCE_TEXT
from schemas.issues import issue
from services import actions, voice_pipeline
from services.writes import ServiceUnavailable, ValidationFailed, WriteError

logger = logging.getLogger("crmvoice")

router = APIRouter(prefix="/actions", tags=["actions"])

# Una transcripción sin al menos dos letras seguidas no dice nada útil
_MEANINGFUL = re.compile(r"[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]{2}")


@router.post("/interpret", status_code=status.HTTP_201_CREATED)
async def interpret_text(body: InterpretTextRequest, current_user: dict = Depends(get_current_user)):
    return await run_in_threadpool(actions.interpret_text, body.text, current_user["user_id"], source="text")


@router.post("/interpret-audio", status_code=status.HTTP_201_CREATED)
async def interpret_audio(file: UploadFile = File(...), current_user: dict = Depends(get_current_user)):
    content, suffix = await read_audio_upload(file)
    try:
        # Whisper (local, CPU-bound) fuera del event loop, con su carga perezosa y su lock
        transcript = await run_in_threadpool(voice_pipeline.transcribe_audio, content, suffix)
    except Exception:
        logger.exception("Error transcribiendo audio")
        raise ServiceUnavailable("transcription_failed", "No se pudo transcribir el audio. Inténtalo de nuevo.")

    transcript = " ".join((transcript or "").split())
    if not _MEANINGFUL.search(transcript):
        raise ValidationFailed([issue("missing", "transcript", "No se ha entendido nada en el audio.")],
                               "No se ha entendido nada en el audio.", extra={"transcript": transcript})
    if len(transcript) > MAX_SOURCE_TEXT:
        raise ValidationFailed([issue("invalid", "transcript", "El audio es demasiado largo para una acción.")],
                               "El audio es demasiado largo para una acción.", extra={"transcript": transcript[:200]})
    try:
        draft = await run_in_threadpool(actions.interpret_text, transcript, current_user["user_id"], source="voice")
    except WriteError as error:
        # La transcripción se devuelve también en el error: el usuario puede corregirla y escribirla
        error.extra.setdefault("transcript", transcript)
        raise
    return {"transcript": transcript, "draft": draft}


@router.get("/{public_id}")
def get_draft(public_id: str, current_user: dict = Depends(get_current_user)):
    return actions.get_draft(public_id, current_user["user_id"])


@router.patch("/{public_id}")
def edit_draft(public_id: str, body: DraftPatch, current_user: dict = Depends(get_current_user)):
    return actions.edit_draft(public_id, current_user["user_id"], body.revision, body.edits)


@router.post("/{public_id}/confirm")
def confirm_draft(public_id: str, body: ConfirmRequest, current_user: dict = Depends(get_current_user)):
    return actions.confirm_draft(public_id, current_user["user_id"], body.revision)


@router.post("/{public_id}/cancel")
def cancel_draft(public_id: str, current_user: dict = Depends(get_current_user)):
    return actions.cancel_draft(public_id, current_user["user_id"])
