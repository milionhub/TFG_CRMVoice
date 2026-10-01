"""
G.1 — Base común de OpenAI (services.openai_client): configuración del
cliente compartido y frontera de errores. Ningún test llama a la API: el
cliente real se construye sin usarse y las llamadas van contra dobles.
"""
from types import SimpleNamespace

import httpx
import openai
import pytest

from services import openai_client
from services.openai_client import (
    AIServiceError, chat_completion_message, chat_completion_text, create_embedding, split_timeout,
)

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


@pytest.mark.parametrize("call", [chat_completion_text, chat_completion_message, create_embedding])
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


# =====================================================================
# G.3: mensaje completo (tool calling) y clasificación de reintentos
# =====================================================================

def _client_returning(response):
    return SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=lambda **kwargs: response)))


def test_chat_completion_message_devuelve_tool_calls_sin_texto():
    tool_call = SimpleNamespace(id="call_1", type="function",
                                function=SimpleNamespace(name="find_entities", arguments="{}"))
    message = SimpleNamespace(content=None, tool_calls=[tool_call])
    response = SimpleNamespace(choices=[SimpleNamespace(message=message)])

    assert chat_completion_message(_client_returning(response), "op", model="m") is message


@pytest.mark.parametrize("response", [
    SimpleNamespace(choices=[]),
    SimpleNamespace(choices=[SimpleNamespace(message=None)]),
    SimpleNamespace(),
], ids=["sin_choices", "mensaje_none", "sin_atributos"])
def test_chat_completion_message_sin_mensaje_es_error_controlado(response):
    with pytest.raises(AIServiceError) as info:
        chat_completion_message(_client_returning(response), "op", model="m")
    assert info.value.retryable is False


_REQUEST = httpx.Request("POST", "https://api.openai.invalid/v1/chat/completions")


def _status_error(cls, status, headers=None):
    response = httpx.Response(status, headers=headers or {}, request=_REQUEST)
    return cls("Incorrect API key provided: sk-test-not-a-real-key", response=response, body=None)


@pytest.mark.parametrize("error, retryable, retry_after", [
    (openai.APIConnectionError(request=_REQUEST), True, None),
    (openai.APITimeoutError(request=_REQUEST), False, None),          # un timeout no se reintenta
    (_status_error(openai.InternalServerError, 503), True, None),
    (_status_error(openai.RateLimitError, 429, {"retry-after": "1.5"}), True, 1.5),
    (_status_error(openai.RateLimitError, 429, {"retry-after": "nunca"}), True, None),
    (_status_error(openai.AuthenticationError, 401), False, None),
    (_status_error(openai.BadRequestError, 400), False, None),
    (RuntimeError("sk-test-not-a-real-key"), False, None),
], ids=["conexion", "timeout", "5xx", "429", "429_sin_numero", "401", "400", "otro"])
def test_clasificacion_de_reintentos(error, retryable, retry_after, caplog):
    with pytest.raises(AIServiceError) as info:
        chat_completion_message(_failing_client(error), "op", model="m")

    assert (info.value.retryable, info.value.retry_after) == (retryable, retry_after)
    assert "sk-test-not-a-real-key" not in str(info.value) + caplog.text


@pytest.mark.parametrize("total, max_connect, expected", [
    (15.0, 3.0, (3.0, 12.0)),    # holgado: conexión con su tope y el resto para leer
    (6.0, 3.0, (2.0, 4.0)),      # justo: la conexión se reduce a un tercio
    (0.3, 3.0, (0.1, 0.2)),      # muy poco: nunca cero ni negativo
])
def test_split_timeout_reparte_el_total(total, max_connect, expected):
    timeout = split_timeout(total, max_connect)
    assert (timeout.connect, timeout.read) == pytest.approx(expected)
    assert timeout.write == timeout.pool == timeout.read
    assert timeout.connect + timeout.read == pytest.approx(total)


@pytest.mark.parametrize("total", [0, -1.0, float("nan")])
def test_split_timeout_rechaza_totales_no_positivos(total):
    with pytest.raises(ValueError):
        split_timeout(total, 3.0)
