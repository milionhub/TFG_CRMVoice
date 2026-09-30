"""
G.1 — Base común de OpenAI (services.openai_client): configuración del
cliente compartido y frontera de errores. Ningún test llama a la API: el
cliente real se construye sin usarse y las llamadas van contra dobles.
"""
from types import SimpleNamespace

import pytest

from services import openai_client
from services.openai_client import AIServiceError, chat_completion_text, create_embedding

LEAKY_ERROR = RuntimeError("Incorrect API key provided: sk-test-not-a-real-key")


@pytest.fixture
def fresh_client(monkeypatch):
    """Fuerza a get_openai_client a construir un cliente nuevo en este test."""
    monkeypatch.setattr(openai_client, "_client", None)


def test_cliente_compartido_con_timeout_y_reintentos_explicitos(fresh_client):
    client = openai_client.get_openai_client()

    assert openai_client.get_openai_client() is client
    assert client.max_retries == openai_client.OPENAI_MAX_RETRIES
    assert client.timeout.read == openai_client.OPENAI_TIMEOUT_SECONDS
    assert client.timeout.connect == openai_client.OPENAI_CONNECT_TIMEOUT_SECONDS


def test_sin_api_key_no_se_crea_el_cliente(fresh_client, monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY")

    with pytest.raises(ValueError, match="OPENAI_API_KEY"):
        openai_client.get_openai_client()


def _failing_client(error):
    def create(**kwargs):
        raise error

    return SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=create)),
                           embeddings=SimpleNamespace(create=create))


@pytest.mark.parametrize("call", [chat_completion_text, create_embedding])
def test_fallo_del_proveedor_se_convierte_en_error_seguro(call, caplog):
    with pytest.raises(AIServiceError) as info:
        call(_failing_client(LEAKY_ERROR), "operacion_de_prueba", model="m")

    error = info.value
    assert error.operation == "operacion_de_prueba"
    assert error.__cause__ is None and error.__suppress_context__  # la excepción original no viaja
    for text in (str(error), caplog.text):
        assert "sk-test-not-a-real-key" not in text and "Incorrect API key" not in text
    assert "RuntimeError" in caplog.text  # diagnóstico: solo el tipo


@pytest.mark.parametrize("response", [
    SimpleNamespace(data=[]),
    SimpleNamespace(data=[SimpleNamespace(embedding=[])]),
    SimpleNamespace(data=[SimpleNamespace(embedding=None)]),
], ids=["sin_data", "vacio", "none"])
def test_embedding_sin_vector_es_error_controlado(response):
    client = SimpleNamespace(embeddings=SimpleNamespace(create=lambda **kwargs: response))

    with pytest.raises(AIServiceError):
        create_embedding(client, "operacion_de_prueba", model="m", input="x")
