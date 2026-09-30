"""
/process-audio (D.4): subida, detección de formato, transcripción (Whisper
sustituido en main.transcribe_audio, donde se usa) y pipeline de resolución
CRM. Nunca se usa Whisper ni FFmpeg reales.
"""
from datetime import datetime
from functools import partial
from types import SimpleNamespace

import pytest

import date_resolver
import main
import whisper_service

THURSDAY = datetime(2026, 10, 1, 12, 0)

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
    """Sustituye a main.transcribe_audio: registra lo recibido y devuelve un texto."""

    def __init__(self, text="texto transcrito", error=None):
        self.text = text
        self.error = error
        self.calls = []

    def __call__(self, audio_bytes, suffix=".wav"):
        self.calls.append({"bytes": audio_bytes, "suffix": suffix})
        if self.error is not None:
            raise self.error
        return self.text


@pytest.fixture
def transcriber(monkeypatch):
    fake = FakeTranscriber()
    monkeypatch.setattr(main, "transcribe_audio", fake)
    return fake


@pytest.fixture(autouse=True)
def fixed_today(monkeypatch):
    monkeypatch.setattr(main, "resolve_relative_date",
                        partial(date_resolver.resolve_relative_date, today=THURSDAY))


def upload(client, user, data, content_type="audio/webm", filename="audio.webm"):
    return client.post("/process-audio", headers=user["headers"],
                       files={"file": (filename, data, content_type)})


# =====================================================================
# AUTH
# =====================================================================

def test_sin_token_401_y_no_transcribe(client, transcriber):
    response = client.post("/process-audio", files={"file": ("a.webm", audio(), "audio/webm")})

    assert response.status_code == 401
    assert transcriber.calls == []


# =====================================================================
# UPLOAD
# =====================================================================

def test_audio_vacio_400(client, user_a, transcriber):
    response = upload(client, user_a, b"")

    assert response.status_code == 400
    assert response.json()["detail"] == "Audio vacío"
    assert transcriber.calls == []


def test_sin_fichero_422(client, user_a, transcriber):
    assert client.post("/process-audio", headers=user_a["headers"]).status_code == 422


def test_audio_en_el_limite_de_tamano_se_acepta(client, user_a, transcriber):
    response = upload(client, user_a, audio(".ogg", size=main.MAX_AUDIO_BYTES), "audio/ogg", "a.ogg")

    assert response.status_code == 200
    assert len(transcriber.calls[0]["bytes"]) == main.MAX_AUDIO_BYTES


def test_audio_demasiado_grande_413(client, user_a, transcriber):
    response = upload(client, user_a, audio(".ogg", size=main.MAX_AUDIO_BYTES + 1), "audio/ogg", "a.ogg")

    assert response.status_code == 413
    assert transcriber.calls == []


@pytest.mark.parametrize("content_type", [
    "audio/webm",
    "audio/webm;codecs=opus",
    "audio/mpeg",
    "AUDIO/OGG",
    "application/octet-stream",  # lo que envía la app (MultipartFile.fromBytes)
    "video/webm",
    "video/mp4",
    "video/ogg",
])
def test_content_types_aceptados(client, user_a, transcriber, content_type):
    assert upload(client, user_a, audio(".webm"), content_type).status_code == 200


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
    # Nombre y content-type genéricos: el formato sale de los bytes
    response = upload(client, user_a, audio(suffix), "application/octet-stream", "grabacion.bin")

    assert response.status_code == 200
    assert transcriber.calls[0]["suffix"] == suffix
    assert transcriber.calls[0]["bytes"] == audio(suffix)


# =====================================================================
# WHISPER (sustituido)
# =====================================================================

def test_error_de_transcripcion_500_controlado(client, user_a, monkeypatch):
    monkeypatch.setattr(main, "transcribe_audio", FakeTranscriber(error=RuntimeError("ffmpeg no encontrado")))

    response = upload(client, user_a, audio())

    assert response.status_code == 500
    assert response.json() == {"detail": "No se pudo transcribir el audio"}


def test_el_endpoint_no_carga_el_modelo_real(client, user_a, transcriber):
    upload(client, user_a, audio())

    assert whisper_service._model is None


# =====================================================================
# PIPELINE: transcripción simulada -> resolución CRM
# =====================================================================

@pytest.fixture
def crm(factory):
    rivera = factory.client("Rivera Distribuciones S.L.", alias="Rivera")
    horizonte = factory.client("Clínica Horizonte S.L.", alias="Horizonte")
    nebula = factory.client("Nebula Logística S.L.", alias="Nebula")
    return SimpleNamespace(
        rivera=rivera, horizonte=horizonte, nebula=nebula,
        luis=factory.contact(rivera, "Luis García"),
        marta=factory.contact(horizonte, "Marta López"),
        nora=factory.contact(nebula, "Nora Quintana"),
        monitor_mar=factory.product("Monitor Mar 24"),
        orbe=factory.product("Portátil Orbe 16"),
        reunion=factory.activity_type_id("Concertar reunión"),
        llamada=factory.activity_type_id("Realizar llamada de seguimiento"),
    )


def process(client, user, monkeypatch, text):
    monkeypatch.setattr(main, "transcribe_audio", FakeTranscriber(text))
    response = upload(client, user, audio())
    assert response.status_code == 200
    return response.json()


EXPECTED_KEYS = {
    "texto", "cliente_detectado", "contacto_detectado", "cliente_id", "contacto_id",
    "cliente_nombre", "contacto_nombre", "accion_detectada", "activity_type_id",
    "fecha_detectada", "products_detected", "cliente_confidence", "contacto_confidence",
    "overall_confidence", "resolution_status",
}


def test_pipeline_ejemplo_manual_rivera(client, user_a, monkeypatch, crm):
    text = "Concertar reunión mañana a las 10 con Luis García de Rivera para presentarle el monitor Mar 24."

    body = process(client, user_a, monkeypatch, text)

    assert set(body) == EXPECTED_KEYS
    assert body["texto"] == text
    assert body["cliente_detectado"] == "Rivera"
    assert body["contacto_detectado"] == "Luis García"
    assert body["cliente_id"] == crm.rivera
    assert body["cliente_nombre"] == "Rivera Distribuciones S.L."
    assert body["contacto_id"] == crm.luis
    assert body["contacto_nombre"] == "Luis García"
    assert body["accion_detectada"] == "Concertar reunión"
    assert body["activity_type_id"] == crm.reunion
    assert body["fecha_detectada"] == "2026-10-02T10:00:00"
    assert body["products_detected"] == [
        {"product_id": crm.monitor_mar, "product_raw": "Monitor Mar 24", "confidence": 100},
    ]
    assert body["cliente_confidence"] == 100
    assert body["contacto_confidence"] == 100
    assert body["overall_confidence"] == 100
    assert body["resolution_status"] == "exact"


# Caso observado manualmente, con la hora en palabras y en cifras (Whisper
# puede devolver cualquiera de las dos formas)
HORIZONTE_TEXT = ("Llamar pasado mañana a las cuatro y media a Marta López de Clínica Horizonte "
                  "para hablarle del portátil Nova 15.")
HORIZONTE_VARIANTS = {
    "palabras": HORIZONTE_TEXT,
    "cifras": HORIZONTE_TEXT.replace("a las cuatro y media", "a las 4 y media"),
}


@pytest.mark.parametrize("variant", HORIZONTE_VARIANTS)
def test_pipeline_ejemplo_horizonte(client, user_a, monkeypatch, crm, variant):
    """
    El regex solo captura "Clínica" como cliente (no resoluble, B13), pero el
    cliente se hereda del contacto resuelto. La hora conserva la media (B11
    corregido). Nova 15 NO existe y en este catálogo no hay ningún producto
    parecido: no se detecta producto (el falso positivo con "Nova 14" es B12,
    documentado en test_entity_resolution).
    """
    body = process(client, user_a, monkeypatch, HORIZONTE_VARIANTS[variant])

    assert body["contacto_id"] == crm.marta
    assert body["contacto_nombre"] == "Marta López"
    assert body["cliente_id"] == crm.horizonte
    assert body["cliente_nombre"] == "Clínica Horizonte S.L."
    assert body["accion_detectada"] == "Realizar llamada de seguimiento"
    assert body["activity_type_id"] == crm.llamada
    assert body["fecha_detectada"] == "2026-10-03T04:30:00"
    assert body["products_detected"] == []
    # 100·0.4 (cliente heredado) + 100·0.3 (contacto) + 0·0.2 (sin producto) + 100·0.1 (acción)
    assert body["overall_confidence"] == 80
    assert body["resolution_status"] == "medium"


@pytest.mark.parametrize("variant", HORIZONTE_VARIANTS)
def test_b11_pipeline_hora_aislada_de_la_resolucion_de_productos(client, user_a, monkeypatch, crm, factory,
                                                                variant):
    """
    B11 aislado de B12: aunque el catálogo tenga "Portátil Nova 14" (que B12
    confundiría con Nova 15), la resolución de productos se sustituye
    explícitamente para comprobar SOLO la fecha/hora.
    """
    factory.product("Portátil Nova 14")
    monkeypatch.setattr(main, "resolve_products", lambda text: [])

    body = process(client, user_a, monkeypatch, HORIZONTE_VARIANTS[variant])

    assert body["fecha_detectada"] == "2026-10-03T04:30:00"


def test_pipeline_contacto_de_otro_cliente_no_se_asocia(client, user_a, monkeypatch, crm):
    # Nora es de Nebula, pero la frase dice Rivera: no se mezcla con Rivera
    body = process(client, user_a, monkeypatch, "Reunión con Nora Quintana de Rivera mañana")

    assert body["cliente_id"] == crm.rivera
    assert body["contacto_id"] is None
    assert body["contacto_nombre"] is None


def test_pipeline_nada_resoluble(client, user_a, monkeypatch, crm):
    body = process(client, user_a, monkeypatch, "Llamar mañana a Pedro Ruiz de Acme")

    assert body["cliente_id"] is None
    assert body["contacto_id"] is None
    assert body["products_detected"] == []
    assert body["accion_detectada"] == "Realizar llamada de seguimiento"
    assert body["fecha_detectada"] == "2026-10-02T00:00:00"  # sin hora -> medianoche
    assert body["resolution_status"] == "unresolved"


def test_pipeline_sin_fecha(client, user_a, monkeypatch, crm):
    body = process(client, user_a, monkeypatch, "Enviar presupuesto a Luis García de Rivera")

    assert body["fecha_detectada"] is None
    assert body["cliente_id"] == crm.rivera


def test_pipeline_no_escribe_en_la_bd(client, user_a, monkeypatch, crm, dbq):
    process(client, user_a, monkeypatch, "Concertar reunión mañana con Luis García de Rivera")

    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0
