import whisper

print("Cargando modelo Whisper...")
model = whisper.load_model("base")

print("Transcribiendo audio...")
result = model.transcribe("audio_prueba.wav", language="es")

print("Texto transcrito:")
print(result["text"])
