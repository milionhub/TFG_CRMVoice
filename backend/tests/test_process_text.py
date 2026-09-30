"""
/process-text (D.4): comportamiento ACTUAL.

Solo aplica las regex de services.text_analysis.analyze_text: NO consulta el CRM (sin ids,
sin nombres oficiales, sin productos) y devuelve la fecha SIN hora. Es la
divergencia B9 con /process-audio; aquí solo se caracteriza (se unificará
en Voice V2). El frontend actual no llama a este endpoint (ApiService.analyzeText
no se usa en ninguna pantalla).
"""
from datetime import datetime
from functools import partial

import pytest

from services import date_resolver, text_analysis

THURSDAY = datetime(2026, 10, 1, 12, 0)
RESPONSE_KEYS = {"cliente", "contacto", "accion", "fecha", "comentario"}


@pytest.fixture(autouse=True)
def fixed_today(monkeypatch):
    """Fecha base fija, parcheada donde se usa (main)."""
    monkeypatch.setattr(text_analysis, "resolve_relative_date",
                        partial(date_resolver.resolve_relative_date, today=THURSDAY))


def process_text(client, user, text):
    response = client.post("/process-text", json={"text": text}, headers=user["headers"])
    assert response.status_code == 200
    return response.json()


def test_texto_valido_extrae_accion_contacto_cliente_y_fecha(client, user_a):
    text = "Concertar reunión mañana a las 10 con Luis García de Rivera para presentarle el monitor Mar 24."

    body = process_text(client, user_a, text)

    assert body == {
        "cliente": "Rivera",
        "contacto": "Luis García",
        "accion": "Concertar reunión",
        "fecha": "2026-10-02",
        "comentario": text,
    }


@pytest.mark.parametrize("text,accion", [
    ("Enviar presupuesto a Nebula", "Enviar presupuesto"),
    ("Mandar la oferta revisada", "Enviar oferta"),
    ("Concertar reunion con el cliente", "Concertar reunión"),
    ("He hecho una visita comercial", "Registrar visita comercial"),
    ("Tengo que llamar a Nora", "Realizar llamada de seguimiento"),
])
def test_accion_detectada(client, user_a, text, accion):
    assert process_text(client, user_a, text)["accion"] == accion


def test_texto_insuficiente_devuelve_campos_vacios(client, user_a):
    assert process_text(client, user_a, "hola") == {
        "cliente": None, "contacto": None, "accion": None, "fecha": None, "comentario": "hola",
    }


def test_texto_vacio(client, user_a):
    body = process_text(client, user_a, "")

    assert body["comentario"] == ""
    assert body["cliente"] is None and body["accion"] is None and body["fecha"] is None


def test_sin_campo_text_422(client, user_a):
    assert client.post("/process-text", json={}, headers=user_a["headers"]).status_code == 422


def test_sin_token_401(client):
    assert client.post("/process-text", json={"text": "hola"}).status_code == 401


def test_b9_process_text_no_consulta_el_crm_ni_devuelve_hora(client, user_a, factory):
    """
    B9 (caracterización, no contrato deseado): aunque el cliente, el contacto y
    el producto existan en el CRM, /process-text no devuelve ids, nombres
    oficiales, productos ni hora; /process-audio sí (ver test_process_audio).
    """
    rivera = factory.client("Rivera Distribuciones S.L.", alias="Rivera")
    factory.contact(rivera, "Luis García")
    factory.product("Monitor Mar 24")

    body = process_text(client, user_a, "Concertar reunión mañana a las 10 con Luis García de Rivera "
                                        "para presentarle el monitor Mar 24.")

    assert set(body) == RESPONSE_KEYS
    assert body["fecha"] == "2026-10-02"  # sin "T10:00:00"


def test_no_hace_llamadas_externas(client, user_a):
    # La guarda de conftest haría fallar el test ante cualquier intento de red u OpenAI
    process_text(client, user_a, "Llamar pasado mañana a Marta López de Clínica Horizonte")


# ---------------------------------------------------------------------
# B13: falsos positivos de las regex de analyze_text (NO se corrigen aquí)
# ---------------------------------------------------------------------

@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B13: la primera palabra en mayúscula se toma como contacto ('Enviar')")
def test_b13_verbo_inicial_no_es_un_contacto(client, user_a):
    assert process_text(client, user_a, "Enviar presupuesto al cliente Nebula")["contacto"] is None


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B13: el cliente absorbe palabras siguientes ('Orion Consultoría Hoy')")
def test_b13_cliente_no_absorbe_palabras_siguientes(client, user_a):
    body = process_text(client, user_a, "Visita comercial a la empresa Orion Consultoría hoy")

    assert body["cliente"] == "Orion Consultoría"
