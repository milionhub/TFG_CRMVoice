"""
Base común para todo el uso de OpenAI en CRMVoice.

- get_openai_client(): el único sitio donde se crea y configura el cliente
  (API key, timeout y reintentos). Los módulos que usan OpenAI guardan la
  instancia compartida en su atributo `client`, que es donde la sustituyen
  los tests.
- AIServiceError: la única excepción que sale de la capa IA. Las del SDK
  (red, timeout, auth, 4xx/5xx) o una respuesta sin el formato esperado se
  convierten en ella sin arrastrar su texto, que puede incluir la API key o
  detalles internos del proveedor. Indica además si el fallo es transitorio
  (retryable: conexión, 5xx o 429) para que el chat decida si reintenta.
"""
import logging
import os

import openai
from openai import OpenAI

logger = logging.getLogger("crmvoice")

# Aplicación interactiva: mejor fallar pronto y mostrar un mensaje que dejar
# la petición colgada (el SDK usa por defecto 600 s y 2 reintentos).
OPENAI_TIMEOUT_SECONDS = 20.0
OPENAI_CONNECT_TIMEOUT_SECONDS = 5.0
OPENAI_MAX_RETRIES = 1

_client = None


class AIServiceError(Exception):
    """
    Fallo controlado de la capa IA. Su mensaje es seguro: solo la operación.
    retryable: fallo transitorio (conexión, 5xx, 429); un timeout NO lo es.
    retry_after: segundos que pide el proveedor (cabecera Retry-After), si los indica.
    """

    def __init__(self, operation: str, *, retryable: bool = False, retry_after: float | None = None):
        super().__init__(f"Fallo del servicio de IA en '{operation}'")
        self.operation = operation
        self.retryable = retryable
        self.retry_after = retry_after


def get_openai_client() -> OpenAI:
    """Cliente OpenAI compartido (se crea en la primera llamada)."""
    global _client
    if _client is None:
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            raise ValueError("OPENAI_API_KEY no encontrada en entorno")
        _client = OpenAI(
            api_key=api_key,
            timeout=openai.Timeout(OPENAI_TIMEOUT_SECONDS, connect=OPENAI_CONNECT_TIMEOUT_SECONDS),
            max_retries=OPENAI_MAX_RETRIES,
        )
    return _client


def _fail(operation: str, reason: str, **kwargs) -> AIServiceError:
    # Solo datos estructurales: nunca el texto de la excepción ni el prompt
    logger.warning("Fallo de OpenAI en %s: %s", operation, reason)
    return AIServiceError(operation, **kwargs)


def _provider_error_reason(error: Exception) -> str:
    status = getattr(error, "status_code", None)
    return f"{type(error).__name__} (HTTP {status})" if status else type(error).__name__


def _retry_after(error: Exception) -> float | None:
    try:
        value = float(error.response.headers.get("retry-after"))
    except (AttributeError, TypeError, ValueError):
        return None
    return value if value >= 0 else None


def _provider_failure(operation: str, error: Exception) -> AIServiceError:
    """Error seguro con la clasificación de reintento (APITimeoutError hereda de APIConnectionError)."""
    timeout = isinstance(error, openai.APITimeoutError)
    retryable = not timeout and isinstance(
        error, (openai.APIConnectionError, openai.InternalServerError, openai.RateLimitError))
    retry_after = _retry_after(error) if isinstance(error, openai.RateLimitError) else None
    return _fail(operation, _provider_error_reason(error), retryable=retryable, retry_after=retry_after)


def chat_completion_text(client, operation: str, **params) -> str:
    """Llama a chat.completions.create y devuelve el texto de la respuesta."""
    try:
        response = client.chat.completions.create(**params)
    except Exception as error:
        raise _provider_failure(operation, error) from None

    try:
        content = response.choices[0].message.content
    except (AttributeError, IndexError, TypeError):
        raise _fail(operation, "respuesta sin choices[0].message.content") from None
    if not isinstance(content, str):
        raise _fail(operation, "respuesta sin texto") from None
    return content


def create_embedding(client, operation: str, **params) -> list[float]:
    """Llama a embeddings.create y devuelve el vector del primer input."""
    try:
        response = client.embeddings.create(**params)
    except Exception as error:
        raise _provider_failure(operation, error) from None

    try:
        vector = response.data[0].embedding
    except (AttributeError, IndexError, TypeError):
        raise _fail(operation, "respuesta sin data[0].embedding") from None
    if not isinstance(vector, list) or not vector:
        raise _fail(operation, "embedding vacío o no válido") from None
    return vector


def split_timeout(total: float, max_connect: float) -> openai.Timeout:
    """
    Timeout de httpx para UNA llamada que debería caber en `total` segundos.
    En httpx el tiempo de conexión y el de lectura se suman, así que se
    reparten: connect = min(max_connect, total / 3) y read (y write/pool) =
    el resto. Ninguno es cero ni negativo. No es un corte exacto de reloj:
    read limita la espera entre bytes, no la duración total de la respuesta.
    """
    if not total > 0:
        raise ValueError("el timeout total debe ser positivo")
    connect = min(max_connect, total / 3)
    return openai.Timeout(total - connect, connect=connect)


def chat_completion_message(client, operation: str, **params):
    """
    Como chat_completion_text, pero devuelve el mensaje completo: con tool
    calling, message.content es None cuando el modelo pide herramientas.
    Qué hacer con el mensaje (texto o tool_calls) lo decide quien llama.
    """
    try:
        response = client.chat.completions.create(**params)
    except Exception as error:
        raise _provider_failure(operation, error) from None

    try:
        message = response.choices[0].message
    except (AttributeError, IndexError, TypeError):
        raise _fail(operation, "respuesta sin choices[0].message") from None
    if message is None:
        raise _fail(operation, "respuesta sin mensaje") from None
    return message
