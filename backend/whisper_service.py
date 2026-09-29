import whisper
import tempfile
import threading
import os

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
