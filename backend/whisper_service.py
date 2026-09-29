import whisper
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

# Cargamos el modelo una sola vez (mejor rendimiento)
model = whisper.load_model("base")

# La transcripción se ejecuta fuera del event loop (threadpool);
# serializamos el acceso al modelo compartido.
_model_lock = threading.Lock()

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
            result = model.transcribe(temp_path, language="es")
        return result["text"]
    finally:
        os.remove(temp_path)
