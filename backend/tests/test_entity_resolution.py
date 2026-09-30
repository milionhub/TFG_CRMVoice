"""
Resolución de entidades (D.4): entity_resolver sobre una SQLite determinista.

Umbrales: cliente/contacto >= 70, producto >= 85. Cliente y contacto:
coincidencia exacta primero, fuzzy después; si el segundo candidato queda a
menos de AMBIGUITY_MARGIN puntos del primero no se elige ninguno (F.1).
Productos: los números de modelo deben coincidir (B12).

No hay "resolución de salesperson": el comercial siempre sale del JWT
(ver test_activities / test_ownership).
"""
from types import SimpleNamespace

import pytest

import db
from services import entity_resolver, text_analysis


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


def test_contacto_nombre_de_pila_repetido_en_el_cliente_es_ambiguo(crm):
    """Dos "Luis" en Rivera: no se elige ninguno en silencio (F.1)."""
    assert entity_resolver.resolve_contact("Luis", crm.rivera) == (None, 100)

    match = entity_resolver.match_contact("Luis", crm.rivera)
    assert match["status"] == "ambiguous"
    assert [c["id"] for c in match["candidates"]] == [crm.luis_garcia, crm.luis_perez]


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


def test_b12_producto_que_solo_difiere_en_el_numero_no_se_resuelve(factory):
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


# =====================================================================
# F.1 — Productos con número de modelo (B12 generalizado) y textos cortos
# =====================================================================

@pytest.fixture
def models(factory):
    """Catálogo con modelos que solo se diferencian en el número (como el de demostración)."""
    return SimpleNamespace(
        nova=factory.product("Portátil Nova 14"),
        aster=factory.product("Portátil Aster 14", aliases=["aster 14", "portatil aster"]),
        orbe=factory.product("Portátil Orbe 16", aliases=["orbe 16", "portatil orbe"]),
        vela=factory.product("Monitor Vela 24", aliases=["vela 24", "monitor vela"]),
        cumbre=factory.product("Monitor Cumbre 32", aliases=["cumbre 32", "monitor cumbre"]),
        eco=factory.product("Auriculares Eco Pro", aliases=["auriculares eco"]),
        licencia=factory.product("Licencia Suite Demo", aliases=["licencia suite"]),
    )


@pytest.mark.parametrize("text", [
    "Nova 15",
    "el Nova 4",
    "nova 140",
    "enseñarle el monitor Vela 27",
    "cambiar al portátil Orbe 18",
    "quiere el portátil Aster 15",     # alias de familia "portatil aster" + otro modelo
    "le enseñé el monitor vela 42",    # alias de familia "monitor vela" + otro modelo
])
def test_f1_modelo_con_otro_numero_no_se_resuelve(models, text):
    assert entity_resolver.resolve_products(text) == []


@pytest.mark.parametrize("text", ["demo", "eco", "monitor", "suite", "licencia", "aster"])
def test_f1_texto_corto_generico_no_es_un_producto(models, text):
    assert entity_resolver.resolve_products(text) == []


@pytest.mark.parametrize("text,expected", [
    ("presentarle el portátil Orbe 16 y el Aster 14", {"orbe", "aster"}),
    ("el monitor Vela 24 y la licencia suite", {"vela", "licencia"}),
    ("le interesan el Orbe 18 y el Orbe 16", {"orbe"}),
    ("pedido de monitor vela para la oficina", {"vela"}),   # alias de familia sin número: vale
])
def test_f1_productos_correctos_en_frase(models, text, expected):
    found = {p["product_id"] for p in entity_resolver.resolve_products(text)}

    assert found == {getattr(models, name) for name in expected}


def test_f1_nombre_y_alias_del_mismo_modelo_se_deduplican(models):
    result = entity_resolver.resolve_products("quiere el portátil orbe 16")

    assert [p["product_id"] for p in result] == [models.orbe]


# =====================================================================
# F.1 — Ambigüedad: no se elige en silencio (API legacy)
# =====================================================================

def test_f1_dos_clientes_con_el_mismo_alias_no_se_elige_ninguno(factory):
    factory.client("Nebula Logística S.L.", alias="Nebula")
    factory.client("Nebula Consultores S.A.", alias="Nebula")

    assert entity_resolver.resolve_client("Nebula") == (None, 100)


def test_f1_mismo_nombre_de_pila_en_dos_clientes_sin_cliente_no_se_elige(factory):
    factory.contact(factory.client("Nebula S.L.", alias="Nebula"), "Nora Quintana")
    factory.contact(factory.client("Lumen S.L.", alias="Lumen"), "Nora Pastor")

    assert entity_resolver.resolve_contact("Nora") == (None, 100)


# =====================================================================
# F.1 — API interna: match_client / match_contact / find_client_in_text
# =====================================================================

def ids(match):
    return [c["id"] for c in match["candidates"]]


def test_normalize_text_quita_tildes_puntuacion_y_espacios():
    assert entity_resolver.normalize_text("  Clínica   HORIZONTE, S.L. ") == "clinica horizonte s l"
    assert entity_resolver.normalize_text("Muñoz-Pérez") == "munoz perez"
    assert entity_resolver.normalize_text(None) == ""


def test_match_client_exacto_por_alias_o_razon_social_sin_forma_juridica(crm):
    by_alias = entity_resolver.match_client("rivera")
    without_legal_form = entity_resolver.match_client("Clínica Horizonte")

    assert by_alias["status"] == "exact" and by_alias["id"] == crm.rivera and by_alias["score"] == 100
    assert by_alias["name"] == "Rivera Distribuciones S.L."
    assert without_legal_form["status"] == "exact" and without_legal_form["id"] == crm.horizonte


def test_match_client_fuzzy_y_no_resuelto(crm):
    fuzzy = entity_resolver.match_client("Riviera")
    missing = entity_resolver.match_client("Acme")

    assert fuzzy["status"] == "fuzzy" and fuzzy["id"] == crm.rivera and ids(fuzzy) == [crm.rivera]
    assert missing == {"id": None, "name": None, "score": missing["score"], "status": "unresolved",
                       "candidates": []}
    assert missing["score"] < entity_resolver.FUZZY_THRESHOLD


def test_match_client_alias_repetido_es_ambiguo_con_candidatos_por_id(factory):
    first = factory.client("Nebula Logística S.L.", alias="Nebula")
    second = factory.client("Nebula Consultores S.A.", alias="Nebula")

    match = entity_resolver.match_client("Nebula")

    assert match["status"] == "ambiguous" and match["id"] is None
    assert ids(match) == [first, second]
    assert entity_resolver.match_client("Nebula") == match  # determinista


@pytest.fixture
def almost_equal_clients(factory):
    return SimpleNamespace(logistica=factory.client("Nebula Logística S.L."),
                           logistico=factory.client("Nebula Logístico S.A."))


def test_match_client_dos_fuzzy_igual_de_cerca_es_ambiguo(almost_equal_clients):
    # 96.8 frente a 96.8: ninguno destaca
    match = entity_resolver.match_client("Nebula Logistic")

    assert match["status"] == "ambiguous"
    assert ids(match) == [almost_equal_clients.logistica, almost_equal_clients.logistico]
    assert entity_resolver.resolve_client("Nebula Logistic") == (None, match["score"])


def test_margen_de_ambiguedad(almost_equal_clients, monkeypatch):
    # 97.0 frente a 90.9: 6.1 puntos, por encima del margen (5) -> se elige
    assert entity_resolver.AMBIGUITY_MARGIN == 5
    assert entity_resolver.match_client("Nebula Logisticas")["id"] == almost_equal_clients.logistica

    monkeypatch.setattr(entity_resolver, "AMBIGUITY_MARGIN", 7)
    assert entity_resolver.match_client("Nebula Logisticas")["status"] == "ambiguous"


def test_match_contact_exacto_fuzzy_y_ambiguo_global(factory):
    nebula = factory.client("Nebula S.L.", alias="Nebula")
    lumen = factory.client("Lumen S.L.", alias="Lumen")
    quintana = factory.contact(nebula, "Nora Quintana")
    pastor = factory.contact(lumen, "Nora Pastor")

    assert entity_resolver.match_contact("nora quintana")["status"] == "exact"
    assert entity_resolver.match_contact("Nora Quintanilla")["id"] == quintana
    ambiguous = entity_resolver.match_contact("Nora")
    assert ambiguous["status"] == "ambiguous" and ids(ambiguous) == [quintana, pastor]
    # Dentro de un cliente ya no hay ambigüedad
    assert entity_resolver.match_contact("Nora", lumen)["id"] == pastor


@pytest.mark.parametrize("text,expected", [
    ("Concertar reunión con Nebula mañana", ("nebula", "Nebula")),
    ("visita a clinica horizonte el martes", ("horizonte", "Clínica Horizonte S.L.")),
    ("hablar con alguien de acme", (None, None)),
    ("la nebulosa de orion", (None, None)),          # solo palabras completas
])
def test_find_client_in_text(crm, text, expected):
    match = entity_resolver.find_client_in_text(text)

    expected_id = getattr(crm, expected[0]) if expected[0] else None
    assert (match["id"], match["mention"]) == (expected_id, expected[1])


def test_find_client_in_text_dos_clientes_distintos_es_ambiguo(crm):
    match = entity_resolver.find_client_in_text("reunión con Rivera y con Horizonte")

    assert match["status"] == "ambiguous" and match["id"] is None
    assert set(ids(match)) == {crm.rivera, crm.horizonte}
