"""
Subida de audio de Voice V2 (POST /actions/interpret-audio): autenticación,
límites, tipos de contenido y formato por cabecera (api/audio.py +
services/voice_pipeline.py). Antes se probaban sobre /process-audio (Voice V1,
retirado en H.5.2); las reglas son las mismas.

Whisper nunca se usa: voice_pipeline.transcribe_audio se sustituye. Para que
una subida válida no llegue al intérprete (OpenAI), la transcripción simulada
es vacía: el endpoint responde 422 "no se ha entendido nada" DESPUÉS de
validar y transcribir, que es lo que se comprueba aquí.
"""
import pytest

from services import voice_pipeline, whisper_service

# Cabeceras mínimas de cada formato que acepta detect_audio_suffix
AUDIO_HEADERS = {
    ".wav": b"RIFF\x24\x00\x00\x00WAVEfmt ",
    ".webm": b"\x1a\x45\xdf\xa3\x9f\x42\x86\x81",
    ".ogg": b"OggS\x00\x02\x00\x00",
    ".m4a": b"\x00\x00\x00\x20ftypM4A \x00\x00",
    ".flac": b"fLaC\x00\x00\x00\x22",
    ".mp3": b"ID3\x04\x00\x00\x00\x00",
    ".amr": b"#!AMR\n\x3c\x00",
    ".caf": b"caff\x00\x01\x00\x00",
    ".aiff": b"FORM\x00\x00\x00\x2eAIFFCOMM",
    ".aac": b"\xff\xf1\x50\x80\x02\x1f\xfc\x00",
}


def audio(suffix=".webm", size=64):
    header = AUDIO_HEADERS[suffix]
    return header + b"\x00" * max(0, size - len(header))


class FakeTranscriber:
    """Sustituye a voice_pipeline.transcribe_audio: registra lo recibido; transcripción vacía."""

    def __init__(self):
        self.calls = []

    def __call__(self, audio_bytes, suffix=".wav"):
        self.calls.append({"bytes": audio_bytes, "suffix": suffix})
        return ""


@pytest.fixture
def transcriber(monkeypatch):
    fake = FakeTranscriber()
    monkeypatch.setattr(voice_pipeline, "transcribe_audio", fake)
    return fake


def upload(client, user, data, content_type="audio/webm", filename="audio.webm"):
    return client.post("/actions/interpret-audio", headers=user["headers"],
                       files={"file": (filename, data, content_type)})


def passed_validation(response) -> bool:
    """Validado y transcrito: con la transcripción vacía, 422 sobre "transcript"."""
    return response.status_code == 422 and response.json()["issues"][0]["field"] == "transcript"


def test_sin_token_401_y_no_transcribe(client, transcriber):
    response = client.post("/actions/interpret-audio", files={"file": ("a.webm", audio(), "audio/webm")})

    assert response.status_code == 401
    assert transcriber.calls == []


def test_audio_vacio_400(client, user_a, transcriber):
    response = upload(client, user_a, b"")

    assert response.status_code == 400
    assert response.json()["detail"] == "Audio vacío"
    assert transcriber.calls == []


def test_sin_fichero_422(client, user_a, transcriber):
    assert client.post("/actions/interpret-audio", headers=user_a["headers"]).status_code == 422
    assert transcriber.calls == []


def test_audio_en_el_limite_de_tamano_se_acepta(client, user_a, transcriber):
    response = upload(client, user_a, audio(".ogg", size=voice_pipeline.MAX_AUDIO_BYTES), "audio/ogg", "a.ogg")

    assert passed_validation(response)
    assert len(transcriber.calls[0]["bytes"]) == voice_pipeline.MAX_AUDIO_BYTES


def test_audio_demasiado_grande_413(client, user_a, transcriber):
    response = upload(client, user_a, audio(".ogg", size=voice_pipeline.MAX_AUDIO_BYTES + 1), "audio/ogg", "a.ogg")

    assert response.status_code == 413
    assert transcriber.calls == []


@pytest.mark.parametrize("content_type", [
    "audio/webm", "audio/webm;codecs=opus", "audio/mpeg", "AUDIO/OGG",
    "application/octet-stream",  # lo que envía la app (MultipartFile.fromBytes)
    "video/webm", "video/mp4", "video/ogg",
])
def test_content_types_aceptados(client, user_a, transcriber, content_type):
    assert passed_validation(upload(client, user_a, audio(".webm"), content_type))


@pytest.mark.parametrize("content_type", ["text/plain", "image/png", "application/json", "video/x-msvideo"])
def test_content_type_no_audio_415(client, user_a, transcriber, content_type):
    response = upload(client, user_a, audio(".webm"), content_type)

    assert response.status_code == 415
    assert transcriber.calls == []


def test_cabecera_desconocida_415_aunque_el_content_type_sea_valido(client, user_a, transcriber):
    response = upload(client, user_a, b"esto no es audio" * 4, "audio/webm")

    assert response.status_code == 415
    assert transcriber.calls == []


@pytest.mark.parametrize("suffix", sorted(AUDIO_HEADERS))
def test_el_sufijo_se_decide_por_la_cabecera_no_por_el_nombre(client, user_a, transcriber, suffix):
    response = upload(client, user_a, audio(suffix), "application/octet-stream", "grabacion.bin")

    assert passed_validation(response)
    assert transcriber.calls[0]["suffix"] == suffix
    assert transcriber.calls[0]["bytes"] == audio(suffix)


def test_el_endpoint_no_carga_el_modelo_real(client, user_a, transcriber):
    upload(client, user_a, audio())

    assert whisper_service._model is None


# =====================================================================
# Voice V1 retirado (H.5.2)
# =====================================================================

@pytest.mark.parametrize("path", ["/process-audio", "/process-text"])
def test_las_rutas_de_voice_v1_ya_no_existen(client, user_a, transcriber, path):
    if path == "/process-audio":
        response = client.post(path, headers=user_a["headers"], files={"file": ("a.webm", audio(), "audio/webm")})
    else:
        response = client.post(path, headers=user_a["headers"], json={"text": "Reunión con Rivera mañana"})

    assert response.status_code in (404, 405)
    assert transcriber.calls == []


def test_v2_sigue_registrado_y_v1_no(client):
    paths = {route.path for route in client.app.routes}
    assert "/actions/interpret-audio" in paths and "/actions/interpret" in paths
    assert not ({"/process-audio", "/process-text"} & paths)
