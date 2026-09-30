"""
whisper_service (D.4): fichero temporal (sufijo, contenido, limpieza) y carga
perezosa del modelo. Nunca se importa Whisper/PyTorch reales: el modelo y el
módulo `whisper` son dobles. Sin rutas propias de Windows (vale para Ubuntu CI).
"""
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

import whisper_service

SUFFIXES = [".wav", ".webm", ".ogg", ".m4a", ".flac", ".mp3", ".amr", ".caf", ".aiff", ".aac"]


class FakeModel:
    """Registra el fichero que recibe (y lo inspecciona mientras existe)."""

    def __init__(self, text=" hola mundo", error=None):
        self.text = text
        self.error = error
        self.seen = []

    def transcribe(self, path, language=None):
        p = Path(path)
        self.seen.append({
            "path": p,
            "existed": p.exists(),
            "content": p.read_bytes() if p.exists() else None,
            "language": language,
        })
        if self.error is not None:
            raise self.error
        return {"text": self.text}


@pytest.fixture
def fake_model(monkeypatch):
    model = FakeModel()
    monkeypatch.setattr(whisper_service, "_get_model", lambda: model)
    return model


# ---------------------------------------------------------------------
# Fichero temporal
# ---------------------------------------------------------------------

@pytest.mark.parametrize("suffix", SUFFIXES)
def test_temporal_con_el_sufijo_y_contenido_correctos_y_se_borra(fake_model, suffix):
    data = b"bytes-de-audio-" + suffix.encode()

    text = whisper_service.transcribe_audio(data, suffix)

    assert text == " hola mundo"
    seen = fake_model.seen[0]
    assert seen["existed"] is True
    assert seen["path"].suffix == suffix
    assert seen["content"] == data
    assert seen["language"] == "es"
    assert not seen["path"].exists()  # borrado tras el éxito


def test_temporal_se_borra_si_la_transcripcion_falla(monkeypatch):
    model = FakeModel(error=RuntimeError("fallo de ffmpeg simulado"))
    monkeypatch.setattr(whisper_service, "_get_model", lambda: model)

    with pytest.raises(RuntimeError, match="ffmpeg"):
        whisper_service.transcribe_audio(b"audio", ".webm")

    assert model.seen[0]["existed"] is True
    assert not model.seen[0]["path"].exists()


def test_temporal_se_borra_si_falla_la_carga_del_modelo(monkeypatch, tmp_path):
    created = []
    real_ntf = whisper_service.tempfile.NamedTemporaryFile

    def tracking_ntf(*args, **kwargs):
        handle = real_ntf(*args, **kwargs)
        created.append(Path(handle.name))
        return handle

    def broken_model():
        raise RuntimeError("no se pudo cargar el modelo")

    monkeypatch.setattr(whisper_service.tempfile, "NamedTemporaryFile", tracking_ntf)
    monkeypatch.setattr(whisper_service, "_get_model", broken_model)

    with pytest.raises(RuntimeError):
        whisper_service.transcribe_audio(b"audio", ".ogg")

    assert len(created) == 1 and not created[0].exists()


def test_sufijo_por_defecto_wav(fake_model):
    whisper_service.transcribe_audio(b"audio")

    assert fake_model.seen[0]["path"].suffix == ".wav"


# ---------------------------------------------------------------------
# Carga perezosa del modelo
# ---------------------------------------------------------------------

@pytest.fixture
def fake_whisper_module(monkeypatch):
    """Módulo `whisper` falso en sys.modules (el real está prohibido en tests)."""
    loads = []

    def load_model(name):
        loads.append((name, threading.current_thread().name))
        time.sleep(0.2)  # agranda la ventana de carrera
        return FakeModel(text=" transcrito")

    monkeypatch.setitem(sys.modules, "whisper", SimpleNamespace(load_model=load_model))
    monkeypatch.setattr(whisper_service, "_model", None)
    return loads


def test_importar_whisper_service_no_carga_el_modelo():
    assert whisper_service._model is None
    assert "whisper" not in sys.modules


def test_el_modelo_se_carga_en_la_primera_transcripcion_y_se_reutiliza(fake_whisper_module):
    assert whisper_service.transcribe_audio(b"uno", ".wav") == " transcrito"
    assert whisper_service.transcribe_audio(b"dos", ".wav") == " transcrito"

    assert [name for name, _ in fake_whisper_module] == ["base"]


def test_carga_concurrente_carga_el_modelo_una_sola_vez(fake_whisper_module):
    results, errors = [], []

    def worker():
        try:
            results.append(whisper_service.transcribe_audio(b"audio", ".webm"))
        except Exception as exc:  # pragma: no cover - solo para diagnosticar
            errors.append(exc)

    threads = [threading.Thread(target=worker, name=f"t{i}") for i in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10)

    assert errors == []
    assert results == [" transcrito"] * 4
    assert len(fake_whisper_module) == 1


def test_si_la_carga_falla_se_reintenta_en_la_siguiente(monkeypatch):
    attempts = []

    def flaky_load(name):
        attempts.append(name)
        if len(attempts) == 1:
            raise RuntimeError("descarga interrumpida")
        return FakeModel(text=" ok")

    monkeypatch.setitem(sys.modules, "whisper", SimpleNamespace(load_model=flaky_load))
    monkeypatch.setattr(whisper_service, "_model", None)

    with pytest.raises(RuntimeError):
        whisper_service.transcribe_audio(b"audio", ".wav")
    assert whisper_service._model is None

    assert whisper_service.transcribe_audio(b"audio", ".wav") == " ok"
    assert len(attempts) == 2
