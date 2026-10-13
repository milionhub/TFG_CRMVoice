"""
Alcance conversacional de un turno del chat (G.4).

No es un clasificador de intenciones: el modelo sigue entendiendo la
pregunta. Aquí solo se detectan, de forma determinista, tres señales
EXPLÍCITAS del mensaje del usuario que el backend necesita para no aplicar a
ciegas el cliente/contacto activo como filtro:

- clear:      pide olvidar el contexto ("Olvida Costa", "Volvamos a general",
              "Quita el filtro de cliente"). El backend lo borra y lo guarda.
- global:     pide todas sus actividades ("en general", "de todos mis clientes").
              Vale solo para este turno: el contexto se conserva.
- contextual: se refiere al contexto ("ellos", "él", "sus", "¿y mañana?") o
              nombra la entidad activa.

Además, mentions_period() detecta un periodo relativo ("hoy", "ayer", "mañana",
"la semana pasada"...): sin contexto activo, el orquestador exige consultar una
herramienta antes de responder (G.6: el modelo contestaba "no tienes nada
mañana" deduciéndolo de respuestas anteriores, o preguntaba sin necesidad).

Con contexto activo y sin ninguna de estas señales, una consulta de
actividades acotada SOLO con el id del estado es ambigua: chat_tools no la
ejecuta y pide aclarar (ver chat_tools.dispatch).
"""
import re
from dataclasses import dataclass

from services.chat_store import ChatState
from services.entity_resolver import normalize_text

# Sobre el texto normalizado (sin tildes ni mayúsculas)
_CLEAR = re.compile(
    r"\b(?:olvida|olvidate|olvidad|olvidemos|quita el filtro|quitar el filtro|quita ese filtro"
    r"|volvamos a (?:lo )?general|volvamos al general|vuelve a (?:lo )?general"
    r"|ya no hablemos de|deja ese cliente|deja el cliente)\b")
_GLOBAL = re.compile(
    r"\b(?:en general|general|globalmente|global|en total|sin filtrar|sin filtro"
    r"|todos mis clientes|todas mis actividades|todos los clientes|todas las actividades|de todos)\b")

# Sobre el texto en minúsculas CON tildes ("él" no es el artículo "el")
_CONTEXTUAL = re.compile(
    r"\b(?:ellos|ellas|ella|él|su|sus|les|ese cliente|este cliente|esa empresa|esta empresa"
    r"|ese contacto|esa persona)\b")

# Periodos relativos de agenda, sobre el texto normalizado ("mañana" -> "manana")
_PERIOD = re.compile(
    r"\b(?:hoy|ayer|anteayer|manana|pasado manana|esta semana|semana pasada|semana anterior"
    r"|semana que viene|proxima semana|semana proxima|semana siguiente|este mes|mes pasado"
    r"|mes que viene|proximo mes)\b")

_MIN_NAME_WORD = 3


@dataclass(frozen=True)
class TurnScope:
    clear: bool = False
    global_: bool = False
    contextual: bool = False

    @property
    def kind(self) -> str | None:
        """'global' | 'contextual' | None (sin señal de alcance)."""
        if self.global_:
            return "global"
        if self.contextual:
            return "contextual"
        return None


def wants_clear(message: str) -> bool:
    return bool(_CLEAR.search(normalize_text(message)))


def mentions_period(message: str) -> bool:
    """El mensaje nombra un periodo relativo de agenda ("¿qué hice ayer?", "¿qué tengo mañana?")."""
    return bool(_PERIOD.search(normalize_text(message)))


def _names_active_entity(words: set[str], state: ChatState) -> bool:
    names = [state.client["name"] if state.client else None, state.contact["name"] if state.contact else None]
    for name in names:
        if name and words & {w for w in normalize_text(name).split() if len(w) >= _MIN_NAME_WORD}:
            return True
    return False


def analyze(message: str, state: ChatState) -> TurnScope:
    """Señales de alcance del mensaje ACTUAL respecto al estado activo (ya limpio si se pidió)."""
    normalized = normalize_text(message)
    lowered = message.lower()
    continuation = re.match(r"^[\s¿¡]*y\b", lowered) is not None          # "¿Y mañana?"
    contextual = (bool(_CONTEXTUAL.search(lowered)) or continuation
                  or _names_active_entity(set(normalized.split()), state))
    return TurnScope(clear=bool(_CLEAR.search(normalized)), global_=bool(_GLOBAL.search(normalized)),
                     contextual=contextual)
