"""
Resolución de entidades (D.4): entity_resolver sobre una SQLite determinista.

Caracteriza el comportamiento ACTUAL (umbrales incluidos: cliente/contacto
>= 70, producto >= 85). Los casos claramente incorrectos se documentan como
xfail(strict=True, raises=AssertionError) con el contrato deseado, sin
cambiar producción.

No hay "resolución de salesperson": el comercial siempre sale del JWT
(ver test_activities / test_ownership).
"""
from types import SimpleNamespace

import pytest

import db
import entity_resolver
from services import text_analysis


@pytest.fixture
def crm(factory):
    rivera = factory.client("Rivera Distribuciones S.L.", alias="Rivera")
    horizonte = factory.client("Clínica Horizonte S.L.", alias="Horizonte")
    nebula = factory.client("Nebula Logística S.L.", alias="Nebula")
    nebula_consultoria = factory.client("Nebula Consultoría S.L.")
    return SimpleNamespace(
        rivera=rivera, horizonte=horizonte, nebula=nebula, nebula_consultoria=nebula_consultoria,
        luis_garcia=factory.contact(rivera, "Luis García"),
        luis_perez=factory.contact(rivera, "Luis Pérez"),
        marta=factory.contact(horizonte, "Marta López"),
        nora=factory.contact(nebula, "Nora Quintana"),
        monitor_mar=factory.product("Monitor Mar 24", aliases=["monitor mar"]),
        orbe=factory.product("Portátil Orbe 16"),
        licencia=factory.product("Licencia Suite"),
    )


# =====================================================================
# CLIENTE
# =====================================================================

@pytest.mark.parametrize("raw", ["Rivera", "rivera", "RIVERA", "Rivera Distribuciones S.L."])
def test_cliente_exacto_por_alias_o_razon_social_sin_distinguir_mayusculas(crm, raw):
    assert entity_resolver.resolve_client(raw) == (crm.rivera, 100)


@pytest.mark.parametrize("raw", ["Clinica Horizonte", "CLÍNICA HORIZONTE", "horizonte"])
def test_cliente_ignora_tildes_y_mayusculas(crm, raw):
    client_id, score = entity_resolver.resolve_client(raw)

    assert client_id == crm.horizonte
    assert score >= entity_resolver.FUZZY_THRESHOLD


def test_cliente_fuzzy_error_de_transcripcion_realista(crm):
    client_id, score = entity_resolver.resolve_client("Riviera")

    assert client_id == crm.rivera
    assert entity_resolver.FUZZY_THRESHOLD <= score < 100


@pytest.mark.parametrize("raw", ["Inexistente SA", "Acme", "de"])
def test_cliente_inexistente_no_se_resuelve(crm, raw):
    client_id, score = entity_resolver.resolve_client(raw)

    assert client_id is None
    assert score < entity_resolver.FUZZY_THRESHOLD


@pytest.mark.parametrize("raw", [None, ""])
def test_cliente_vacio(crm, raw):
    assert entity_resolver.resolve_client(raw) == (None, 0)


def test_cliente_nombre_parcial_de_una_palabra_generica_no_se_resuelve(crm):
    # "de Clínica Horizonte" -> el regex de main captura solo "Clínica"
    client_id, _ = entity_resolver.resolve_client("Clínica")

    assert client_id is None


def test_cliente_con_nombre_parecido_elige_el_mas_similar(crm):
    # Dos clientes "Nebula": el alias exacto gana; el nombre completo, al otro
    assert entity_resolver.resolve_client("Nebula")[0] == crm.nebula
    assert entity_resolver.resolve_client("Nebula Consultoría")[0] == crm.nebula_consultoria


def test_cliente_sin_catalogo(dbq):
    assert entity_resolver.resolve_client("Rivera")[0] is None


# =====================================================================
# CONTACTO
# =====================================================================

@pytest.mark.parametrize("raw", ["Luis García", "luis garcia", "LUIS GARCÍA"])
def test_contacto_exacto_sin_distinguir_mayusculas_ni_tildes(crm, raw):
    assert entity_resolver.resolve_contact(raw) == (crm.luis_garcia, 100)


def test_contacto_fuzzy_realista(crm):
    contact_id, score = entity_resolver.resolve_contact("Martha Lopes")

    assert contact_id == crm.marta
    assert entity_resolver.FUZZY_THRESHOLD <= score < 100


def test_contacto_restringido_al_cliente_indicado(crm):
    # Marta existe, pero es de Horizonte: no se asocia a Rivera
    assert entity_resolver.resolve_contact("Marta López", crm.rivera)[0] is None
    assert entity_resolver.resolve_contact("Marta López", crm.horizonte) == (crm.marta, 100)


def test_contacto_sin_cliente_busca_en_todo_el_catalogo(crm):
    assert entity_resolver.resolve_contact("Nora Quintana") == (crm.nora, 100)


def test_contacto_solo_nombre_de_pila(crm):
    assert entity_resolver.resolve_contact("Marta") == (crm.marta, 100)


def test_contacto_nombre_de_pila_ambiguo_no_se_detecta_como_ambiguo(crm):
    """
    Comportamiento actual: con dos "Luis" en Rivera se devuelve uno de ellos
    con score 100, sin señal de ambigüedad. No se fija CUÁL (hoy, el de menor
    id); se documenta como riesgo para Voice V2.
    """
    contact_id, score = entity_resolver.resolve_contact("Luis", crm.rivera)

    assert contact_id in {crm.luis_garcia, crm.luis_perez}
    assert score == 100


@pytest.mark.parametrize("raw", ["Pedro", "Pedro Ruiz"])
def test_contacto_inexistente(crm, raw):
    contact_id, score = entity_resolver.resolve_contact(raw)

    assert contact_id is None
    assert score < entity_resolver.FUZZY_THRESHOLD


@pytest.mark.parametrize("raw", [None, ""])
def test_contacto_vacio(crm, raw):
    assert entity_resolver.resolve_contact(raw) == (None, 0)


# =====================================================================
# PRODUCTOS
# =====================================================================

def detected(text):
    return {p["product_id"]: p for p in entity_resolver.resolve_products(text)}


def test_producto_por_nombre_oficial_dentro_de_una_frase(crm):
    found = detected("para presentarle el monitor Mar 24 al cliente")

    assert list(found) == [crm.monitor_mar]
    assert found[crm.monitor_mar]["product_raw"] == "Monitor Mar 24"
    assert found[crm.monitor_mar]["confidence"] == 100


def test_producto_por_alias(crm):
    assert list(detected("le interesa el monitor mar")) == [crm.monitor_mar]


def test_producto_ignora_tildes(crm):
    assert list(detected("quiere el portatil orbe 16")) == [crm.orbe]


def test_varios_productos_en_un_texto(crm):
    assert set(detected("el Portátil Orbe 16 y la Licencia Suite")) == {crm.orbe, crm.licencia}


def test_producto_nombre_y_alias_se_deduplican(crm):
    # "monitor mar 24" coincide con el nombre y con el alias: un solo resultado
    result = entity_resolver.resolve_products("el monitor mar 24")

    assert [p["product_id"] for p in result] == [crm.monitor_mar]


@pytest.mark.parametrize("text", ["nada que ver con productos", "", None])
def test_texto_sin_productos(crm, text):
    assert entity_resolver.resolve_products(text) == []


def test_producto_inexistente_sin_parecidos_no_se_detecta(crm):
    # Nova 15 no existe y no hay ningún "Nova" en el catálogo
    assert entity_resolver.resolve_products("hablarle del portátil Nova 15") == []


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B12: 'Nova 15' se resuelve como 'Portátil Nova 14' (partial_ratio 93.75 >= 85)")
def test_b12_producto_que_solo_difiere_en_el_numero_no_deberia_resolverse(factory):
    factory.product("Portátil Nova 14")

    assert entity_resolver.resolve_products("hablarle del portátil Nova 15") == []


# =====================================================================
# TIPO DE ACTIVIDAD
# =====================================================================

def test_cada_accion_de_detect_action_resuelve_a_un_tipo_de_actividad(dbq):
    """detect_action (text_analysis) y db.ACTIVITY_TYPES deben seguir alineados."""
    texts = ["enviar presupuesto", "mandar la oferta", "concertar reunión", "visita", "llamar"]
    actions = {text_analysis.detect_action(t) for t in texts}

    assert actions == set(db.ACTIVITY_TYPES)
    for action in actions:
        assert entity_resolver.resolve_activity_type(action) is not None


def test_tipo_de_actividad_ignora_tildes_y_mayusculas(dbq):
    assert (entity_resolver.resolve_activity_type("CONCERTAR REUNION")
            == entity_resolver.resolve_activity_type("Concertar reunión"))


@pytest.mark.parametrize("raw", ["Otra acción", "", None])
def test_tipo_de_actividad_desconocido(dbq, raw):
    assert entity_resolver.resolve_activity_type(raw) is None
