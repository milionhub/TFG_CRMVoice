"""
Lectura segura de un audio subido para /actions/interpret-audio (Voice V2):
una sola implementación de los límites.

- tipo de contenido de audio (la app suele enviar application/octet-stream);
- tamaño máximo (voice_pipeline.MAX_AUDIO_BYTES), leyendo como mucho uno más;
- audio no vacío;
- formato real comprobado por la cabecera del fichero (magic bytes).
"""
from fastapi import HTTPException, UploadFile

from services import voice_pipeline


async def read_audio_upload(file: UploadFile) -> tuple[bytes, str]:
    """(contenido, extensión). Lanza HTTPException 415 / 413 / 400 con mensajes seguros."""
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

    return content, suffix
