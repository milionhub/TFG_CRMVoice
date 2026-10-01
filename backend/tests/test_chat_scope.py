"""
G.4 — Señales de alcance conversacional (services.chat_scope): borrar el
contexto, pedir todo (global) o referirse al contexto. Deterministas y sin
clasificar intenciones: lo demás lo entiende el modelo.
"""
import pytest

from services.chat_scope import analyze, wants_clear
from services.chat_store import ChatState

COSTA = ChatState(client={"id": 4, "name": "Diputacion Costa Verde"})
WITH_CONTACT = ChatState(client={"id": 1, "name": "Tecnologia Rivera SL"},
                         contact={"id": 3, "name": "Carlos Perez", "client_id": 1})


@pytest.mark.parametrize("message", [
    "Olvida Costa.", "Olvida ese cliente.", "olvídate de Rivera", "Volvamos a general.", "volvamos a lo general",
    "Quita el filtro de cliente.", "Ya no hablemos de Rivera.", "Olvida Costa. ¿Qué hice ayer?",
])
def test_borrar_contexto(message):
    assert wants_clear(message)


@pytest.mark.parametrize("message", [
    "¿Qué hice la semana pasada?", "¿Qué tengo mañana en general?", "¿Cómo va Costa?", "No olvides llamar a Rivera",
])
def test_no_borra_el_contexto(message):
    assert not wants_clear(message)


@pytest.mark.parametrize("message", [
    "¿Qué tengo mañana en general?", "¿Qué hice ayer de todos mis clientes?", "Globalmente, ¿qué tengo esta semana?",
    "Sin filtrar por cliente, ¿qué hice ayer?", "¿Qué tengo esta semana con todos los clientes?",
])
def test_alcance_global_explicito(message):
    assert analyze(message, COSTA).kind == "global"


@pytest.mark.parametrize("message, state", [
    ("¿Y cuándo fue mi última actividad con ellos?", COSTA),
    ("¿Qué productos hemos tratado con ellos?", COSTA),
    ("¿Y sus productos?", COSTA),
    ("¿Y mañana?", COSTA),                                   # continuación corta
    ("¿Qué hice la semana pasada con Costa?", COSTA),        # nombra la entidad activa
    ("Con Costa.", COSTA),                                   # respuesta a la aclaración
    ("¿Qué tengo mañana con él?", WITH_CONTACT),
    ("¿Qué tengo con Carlos?", WITH_CONTACT),                # nombre del contacto activo
])
def test_referencia_contextual(message, state):
    assert analyze(message, state).kind == "contextual"


@pytest.mark.parametrize("message", [
    "¿Qué hice la semana pasada?", "¿Qué tengo mañana?", "¿Qué hice ayer?",
    "¿Qué tengo el lunes?",                                  # "el" (artículo) no es "él"
])
def test_sin_senal_de_alcance(message):
    assert analyze(message, COSTA).kind is None


def test_sin_contexto_activo_el_nombre_no_cuenta():
    assert analyze("¿Qué hice con Costa?", ChatState()).kind is None
