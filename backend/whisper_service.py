import whisper
import tempfile
import os

# Cargamos el modelo una sola vez (mejor rendimiento)
model = whisper.load_model("base")

def transcribe_audio(audio_bytes: bytes) -> str:
    """
    Transcribe audio recibido como bytes usando Whisper.
    Devuelve el texto transcrito.
    """
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(audio_bytes)
        temp_path = tmp.name

    try:
        result = model.transcribe(temp_path, language="es")
        return result["text"]
    finally:
        os.remove(temp_path)
