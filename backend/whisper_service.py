import tempfile
import threading
import logging
import shutil
import os

# Whisper decodifica el audio llamando al ejecutable ffmpeg (dependencia del
# sistema, no de pip). Sin él, cada transcripción falla con un error genérico.
if shutil.which("ffmpeg") is None:
    logging.getLogger("crmvoice").warning(
        "FFmpeg no está en el PATH: /process-audio no podrá transcribir. "
        "Instálalo y comprueba con 'ffmpeg -version'."
    )

# El modelo se carga una sola vez, en la primera transcripción (no al
# importar): así importar el backend no carga torch ni descarga el modelo.
_model = None

# La transcripción se ejecuta fuera del event loop (threadpool);
# serializamos la carga y el acceso al modelo compartido.
_model_lock = threading.Lock()


def _get_model():
    """Devuelve el modelo Whisper, cargándolo si hace falta. Llamar con _model_lock."""
    global _model
    if _model is None:
        import whisper
        _model = whisper.load_model("base")
    return _model


def transcribe_audio(audio_bytes: bytes, suffix: str = ".wav") -> str:
    """
    Transcribe audio recibido como bytes usando Whisper.
    Devuelve el texto transcrito.
    """
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(audio_bytes)
        temp_path = tmp.name

    try:
        with _model_lock:
            result = _get_model().transcribe(temp_path, language="es")
        return result["text"]
    finally:
        os.remove(temp_path)
