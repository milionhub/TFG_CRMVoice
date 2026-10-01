"""
G.2 — Herramientas CRM de solo lectura (services.crm_tools).

Escenario fijo: NOW = miércoles 2026-10-07 12:00 (semana: lunes 05 a
domingo 11). Dos comerciales con actividades marcadas (A_ONLY / B_ONLY)
para comprobar que ninguna herramienta mezcla actividad privada. Catálogo
y facturación son globales por diseño.
"""
import hashlib
import json
from datetime import datetime
from types import SimpleNamespace

import pytest

import db
from services import crm_tools, semantic_search_service, voice_pipeline
from services.crm_tools import ToolArgumentError
from services.openai_client import AIServiceError

NOW = datetime(2026, 10, 7, 12, 0)
A_ONLY = "A_ONLY_5E1B"
B_ONLY = "B_ONLY_77C4"


@pytest.fixture
def world(factory, user_a, user_b):
    rivera = factory.client("Rivera Industrial S.L.", alias="Rivera")
    sierra = factory.client("Sierra Norte S.A.", alias="Sierra Norte")
    lucas = factory.client("Clínica San Lucas S.L.", alias="San Lucas")
    delta = factory.client("Delta Ingeniería S.L.", alias="Delta")
    orion = factory.client("Orion Consultoría S.L.", alias="Orion")

    marta_lopez = factory.contact(rivera, "Marta López")
    marta_ruiz = factory.contact(sierra, "Marta Ruiz")
    pablo = factory.contact(lucas, "Pablo Gil")

    monitor = factory.product("Monitor Vela 27", 300, aliases=("pantalla vela",))
    silla = factory.product("Silla Ergonómica", 150)
    mesa = factory.product("Mesa Elevable", 500)
    factory.product("Lámpara Sin Uso", 40)

    visita = factory.activity_type_id("Registrar visita comercial")
    llamada = factory.activity_type_id("Realizar llamada de seguimiento")
    reunion = factory.activity_type_id("Concertar reunión")
    a, b = user_a["id"], user_b["id"]

    def act(owner, client, when, *, contact=None, type_id=reunion, products=(), tag=None, embedding=None):
        tag = tag or (A_ONLY if owner == a else B_ONLY)
        return factory.activity(owner, client, contact_id=contact, activity_type_id=type_id, datetime_iso=when,
                                comentario=f"{tag} {when}", products=[(p, "raw") for p in products],
                                embedding=embedding)

    ids = SimpleNamespace(
        a_rivera_old=act(a, rivera, "2026-09-01T09:00:00", type_id=llamada, embedding=[0.0, 1.0, 0.0]),
        a_rivera_past=act(a, rivera, "2026-10-01T10:00:00", type_id=visita, products=[monitor],
                          embedding=[1.0, 0.0, 0.0]),
        a_rivera_tomorrow=act(a, rivera, "2026-10-08T09:30:00", contact=marta_lopez, products=[silla]),
        a_rivera_later=act(a, rivera, "2026-10-20T10:00:00"),
        a_sierra_old=act(a, sierra, "2026-06-15T10:00:00"),
        a_sierra_today_am=act(a, sierra, "2026-10-07T09:00:00", contact=marta_ruiz),
        # Formato con milisegundos, como algunas actividades reales
        a_sierra_today_pm=act(a, sierra, "2026-10-07T16:00:00.000"),
        a_lucas=act(a, lucas, "2026-10-06T11:00:00", contact=pablo, products=[monitor, mesa],
                    embedding=[0.9, 0.1, 0.0]),
        a_delta_next=act(a, delta, "2026-10-12T10:00:00"),  # lunes de la semana siguiente
        b_rivera_tomorrow=act(b, rivera, "2026-10-08T10:00:00", contact=marta_lopez, products=[mesa],
                              embedding=[1.0, 0.0, 0.0]),
        b_rivera_past=act(b, rivera, "2026-10-02T10:00:00", contact=marta_lopez, embedding=[1.0, 0.0, 0.0]),
        b_orion=[act(b, orion, f"2026-09-2{i}T10:00:00") for i in range(3)],
    )

    conn = db.get_connection()
    for client_id, fecha, lines in [
        (rivera, "2026-05-01", [(monitor, 2, 300, 600), (silla, 2, 200, 400)]),
        (rivera, "2026-08-01", [(mesa, 1, 500, 500)]),
        (sierra, "2026-07-01", [(mesa, 6, 500, 3000)]),
    ]:
        invoice = conn.execute("INSERT INTO invoices (fecha, client_id) VALUES (?, ?)", (fecha, client_id)).lastrowid
        conn.executemany(
            "INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (?, ?, ?, ?, ?)",
            [(invoice, *line) for line in lines])
    conn.commit()
    conn.close()

    return SimpleNamespace(a=a, b=b, rivera=rivera, sierra=sierra, lucas=lucas, delta=delta, orion=orion,
                           marta_lopez=marta_lopez, marta_ruiz=marta_ruiz, pablo=pablo,
                           monitor=monitor, silla=silla, mesa=mesa, ids=ids)


def activity_ids(result):
    return [a["id"] for a in result["activities"]]


# =====================================================================
# find_entities (reutiliza la Fase F)
# =====================================================================

def test_find_entities_cliente_en_texto_libre(world):
    result = crm_tools.find_entities("¿Qué sabes de Rivera?", world.a)

    assert result["found"] is True
    assert result["client"] | {"candidates": None} == {
        "id": world.rivera, "name": "Rivera Industrial S.L.", "mention": "Rivera", "status": "exact",
        "origin": "detected", "score": 100.0, "candidates": None,
    }
    assert result["contact"]["id"] is None and result["contact"]["mention"] is None


def test_find_entities_contacto_hereda_su_cliente(world):
    result = crm_tools.find_entities("¿Tengo algo próximo con Marta López?", world.a)

    assert result["contact"]["id"] == world.marta_lopez
    assert result["contact"]["client_id"] == world.rivera and result["contact"]["status"] == "exact"
    assert result["client"]["id"] == world.rivera
    assert result["client"]["status"] == "inherited" and result["client"]["origin"] == "inherited"


def test_find_entities_ambiguo_no_elige(world):
    result = crm_tools.find_entities(None, world.a, contact_name="Marta")

    assert result["found"] is False
    assert result["contact"]["status"] == "ambiguous" and result["contact"]["id"] is None
    assert {(c["id"], c["client_id"]) for c in result["contact"]["candidates"]} == {
        (world.marta_lopez, world.rivera), (world.marta_ruiz, world.sierra)}


def test_find_entities_contacto_de_otro_cliente_es_conflicto(world):
    result = crm_tools.find_entities(None, world.a, client_name="Rivera", contact_name="Marta Ruiz")

    assert result["client"]["id"] == world.rivera
    assert result["contact"]["status"] == "conflict" and result["contact"]["id"] is None
    assert [c["client_name"] for c in result["contact"]["candidates"]] == ["Sierra Norte S.A."]


def test_find_entities_sin_coincidencias(world):
    result = crm_tools.find_entities(None, world.a, client_name="Zeta Global")

    assert result["found"] is False
    assert result["client"]["status"] == "unresolved" and result["client"]["id"] is None


@pytest.mark.parametrize("question,client,contact", [
    ("¿Cuándo fue mi última actividad con Sierra Norte?", "sierra", None),
    ("¿Qué productos hemos tratado con San Lucas?", "lucas", None),
    ("Prepárame los datos para una reunión con Rivera", "rivera", None),
    ("¿Tengo algo próximo con Marta López?", "rivera", "marta_lopez"),
])
def test_find_entities_en_las_preguntas_del_chat(world, question, client, contact):
    result = crm_tools.find_entities(question, world.a)

    assert result["client"]["id"] == getattr(world, client)
    assert result["contact"]["id"] == (getattr(world, contact) if contact else None)


@pytest.mark.parametrize("text", [
    "reunión mañana con Marta López",
    "visita a Rivera con Marta Ruiz",
    "llamada con Pablo de San Lucas",
])
def test_find_entities_resuelve_igual_que_process_audio(world, text):
    tool = crm_tools.find_entities(text, world.a)
    voice = voice_pipeline.analyze_transcription(text)

    assert (tool["client"]["id"], tool["client"]["status"]) == (voice["cliente_id"], voice["cliente_status"])
    assert (tool["contact"]["id"], tool["contact"]["status"]) == (voice["contacto_id"], voice["contacto_status"])


@pytest.mark.parametrize("kwargs", [
    {"text": None},
    {"text": "Rivera", "client_name": "Rivera"},
    {"text": "   "},
    {"text": "x" * 501},
])
def test_find_entities_argumentos_invalidos(world, kwargs):
    text = kwargs.pop("text")
    with pytest.raises(ToolArgumentError):
        crm_tools.find_entities(text, world.a, **kwargs)


# =====================================================================
# list_activities: fechas, filtros, orden y límites
# =====================================================================

def test_manana_solo_mis_actividades(world):
    result = crm_tools.list_activities(world.a, temporal_scope="tomorrow", now=NOW)

    assert activity_ids(result) == [world.ids.a_rivera_tomorrow]  # la de B del mismo día no aparece
    item = result["activities"][0]
    assert item["client"] == {"id": world.rivera, "name": "Rivera Industrial S.L."}
    assert item["contact"] == {"id": world.marta_lopez, "name": "Marta López"}
    assert item["products"] == [{"id": world.silla, "name": "Silla Ergonómica"}]
    assert item["timing"] == "upcoming"


def test_hoy_incluye_pasadas_y_proximas_del_dia_en_orden(world):
    result = crm_tools.list_activities(world.a, temporal_scope="today", now=NOW)

    assert activity_ids(result) == [world.ids.a_sierra_today_am, world.ids.a_sierra_today_pm]
    assert [a["timing"] for a in result["activities"]] == ["past", "upcoming"]
    assert result["order"] == "asc"


def test_esta_semana_es_de_lunes_a_domingo(world):
    result = crm_tools.list_activities(world.a, temporal_scope="this_week", now=NOW)

    assert activity_ids(result) == [world.ids.a_lucas, world.ids.a_sierra_today_am, world.ids.a_sierra_today_pm,
                                    world.ids.a_rivera_tomorrow]
    next_week = crm_tools.list_activities(world.a, temporal_scope="next_week", now=NOW)
    assert activity_ids(next_week) == [world.ids.a_delta_next]


def test_proximas_ascendente_y_pasadas_descendente(world):
    upcoming = crm_tools.list_activities(world.a, temporal_scope="upcoming", now=NOW)
    past = crm_tools.list_activities(world.a, temporal_scope="past", limit=3, now=NOW)

    assert activity_ids(upcoming) == [world.ids.a_sierra_today_pm, world.ids.a_rivera_tomorrow,
                                      world.ids.a_delta_next, world.ids.a_rivera_later]
    assert activity_ids(past) == [world.ids.a_sierra_today_am, world.ids.a_lucas, world.ids.a_rivera_past]
    assert past["order"] == "desc" and past["has_more"] is True


def test_ultima_actividad_con_un_cliente(world):
    result = crm_tools.list_activities(world.a, client_id=world.sierra, temporal_scope="past", limit=1, now=NOW)

    assert activity_ids(result) == [world.ids.a_sierra_today_am]


def test_rango_de_fechas_inclusivo_en_ambos_extremos(world):
    result = crm_tools.list_activities(world.a, date_from="2026-10-01", date_to="2026-10-06", now=NOW)

    assert activity_ids(result) == [world.ids.a_rivera_past, world.ids.a_lucas]
    single_day = crm_tools.list_activities(world.a, date_from="2026-10-07", date_to="2026-10-07", now=NOW)
    assert activity_ids(single_day) == [world.ids.a_sierra_today_am, world.ids.a_sierra_today_pm]


def test_filtros_combinados_contacto_y_ambito(world):
    mine = crm_tools.list_activities(world.a, contact_id=world.marta_lopez, temporal_scope="upcoming", now=NOW)
    theirs = crm_tools.list_activities(world.b, contact_id=world.marta_lopez, temporal_scope="upcoming", now=NOW)

    assert activity_ids(mine) == [world.ids.a_rivera_tomorrow]
    assert activity_ids(theirs) == [world.ids.b_rivera_tomorrow]


def test_filtro_por_cliente_no_rompe_el_aislamiento(world):
    result = crm_tools.list_activities(world.b, client_id=world.rivera, now=NOW)

    assert activity_ids(result) == [world.ids.b_rivera_tomorrow, world.ids.b_rivera_past]


def test_sin_resultados_found_false(world):
    result = crm_tools.list_activities(world.a, client_id=world.orion, now=NOW)

    assert result["found"] is False and result["activities"] == [] and result["has_more"] is False


@pytest.mark.parametrize("kwargs", [
    {"limit": 0}, {"limit": 51}, {"limit": True}, {"limit": "5"},
    {"temporal_scope": "pending"}, {"date_from": "07/10/2026"},
    {"date_from": "2026-10-08", "date_to": "2026-10-01"}, {"client_id": "1 OR 1=1"},
])
def test_list_activities_argumentos_invalidos(world, kwargs):
    with pytest.raises(ToolArgumentError):
        crm_tools.list_activities(world.a, now=NOW, **kwargs)


# =====================================================================
# search_activities (embeddings con un doble; nunca OpenAI real)
# =====================================================================

@pytest.fixture
def embeddings(monkeypatch):
    fake = SimpleNamespace(calls=[], vector=[1.0, 0.0, 0.0], error=None)

    def create(**kwargs):
        fake.calls.append(kwargs)
        if fake.error:
            raise fake.error
        return SimpleNamespace(data=[SimpleNamespace(embedding=list(fake.vector))])

    monkeypatch.setattr(semantic_search_service, "client", SimpleNamespace(embeddings=SimpleNamespace(create=create)))
    return fake


def test_busqueda_semantica_aislada_y_ordenada(world, embeddings):
    result = crm_tools.search_activities("visita con pantallas", world.a, now=NOW)

    assert [r["activity"]["id"] for r in result["results"]] == [
        world.ids.a_rivera_past, world.ids.a_lucas, world.ids.a_rivera_old]
    assert [r["score"] for r in result["results"]] == sorted((r["score"] for r in result["results"]), reverse=True)
    assert embeddings.calls == [{"model": "text-embedding-3-small", "input": "visita con pantallas"}]


def test_busqueda_semantica_por_cliente_y_limite(world, embeddings):
    result = crm_tools.search_activities("visita", world.b, client_id=world.rivera, limit=1, now=NOW)

    # Las dos actividades de B con Rivera empatan: a igual score, menor id
    assert [r["activity"]["id"] for r in result["results"]] == [world.ids.b_rivera_tomorrow]
    assert result["count"] == 1


def test_busqueda_semantica_error_de_ia_y_query_vacia(world, embeddings):
    with pytest.raises(ToolArgumentError):
        crm_tools.search_activities("  ", world.a)
    assert embeddings.calls == []  # sin consulta no se llama a OpenAI

    embeddings.error = RuntimeError("Incorrect API key provided: sk-test-not-a-real-key")
    with pytest.raises(AIServiceError):
        crm_tools.search_activities("visita", world.a)


# =====================================================================
# get_client_overview / get_contact
# =====================================================================

def test_vista_de_cliente(world):
    result = crm_tools.get_client_overview(world.rivera, world.a, now=NOW)

    assert result["client"]["name"] == "Rivera Industrial S.L." and result["client"]["alias"] == "Rivera"
    assert [c["name"] for c in result["contacts"]] == ["Marta López"]
    activity = result["activity"]
    assert (activity["scope"], activity["total"], activity["past"], activity["upcoming"]) == ("salesperson", 4, 2, 2)
    assert activity["last_activity"]["id"] == world.ids.a_rivera_past
    assert activity["next_activity"]["id"] == world.ids.a_rivera_tomorrow
    assert {t["activity_type"]["name"]: t["count"] for t in activity["by_type"]} == {
        "Concertar reunión": 2, "Registrar visita comercial": 1, "Realizar llamada de seguimiento": 1}
    assert result["billing"] == {
        "scope": "global", "total_billed": 1500, "invoice_count": 2, "average_ticket": 750.0,
        "last_invoice_date": "2026-08-01",
        "top_product": {"id": world.monitor, "name": "Monitor Vela 27", "total_billed": 600},
    }
    # Tratados: solo en actividades de A (la Mesa solo la trató B); a igual recuento, el más reciente
    assert [p["name"] for p in result["products"]["discussed"]] == ["Silla Ergonómica", "Monitor Vela 27"]
    assert [p["name"] for p in result["products"]["invoiced"]] == ["Monitor Vela 27", "Mesa Elevable",
                                                                   "Silla Ergonómica"]


def test_vista_de_cliente_actividad_por_comercial_facturacion_global(world):
    a = crm_tools.get_client_overview(world.rivera, world.a, now=NOW)
    b = crm_tools.get_client_overview(world.rivera, world.b, now=NOW)

    assert b["activity"]["total"] == 2 and b["activity"]["next_activity"]["id"] == world.ids.b_rivera_tomorrow
    assert a["billing"] == b["billing"] and a["products"]["invoiced"] == b["products"]["invoiced"]
    assert [p["name"] for p in b["products"]["discussed"]] == ["Mesa Elevable"]


def test_cliente_sin_actividad_ni_facturacion(world):
    result = crm_tools.get_client_overview(world.orion, world.a, now=NOW)

    assert result["activity"]["total"] == 0 and result["activity"]["last_activity"] is None
    assert result["billing"]["total_billed"] == 0 and result["billing"]["average_ticket"] is None
    assert result["billing"]["top_product"] is None


def test_contacto_con_actividad_del_comercial(world):
    a = crm_tools.get_contact(world.marta_lopez, world.a, now=NOW)
    b = crm_tools.get_contact(world.marta_lopez, world.b, now=NOW)

    assert a["contact"]["name"] == "Marta López"
    assert a["client"] == {"id": world.rivera, "name": "Rivera Industrial S.L."}
    assert a["activity"]["next_activity"]["id"] == world.ids.a_rivera_tomorrow
    assert a["recent_activities"] == [] and a["activity"]["total"] == 1
    assert [x["id"] for x in b["recent_activities"]] == [world.ids.b_rivera_past]
    assert b["activity"]["next_activity"]["id"] == world.ids.b_rivera_tomorrow


@pytest.mark.parametrize("tool", ["get_client_overview", "get_contact", "prepare_meeting_context",
                                  "get_client_products"])
def test_entidad_inexistente_found_false(world, tool):
    result = getattr(crm_tools, tool)(9999, world.a)

    assert result["found"] is False


# =====================================================================
# crm_rankings
# =====================================================================

def test_ranking_actividad_por_comercial(world):
    a = crm_tools.crm_rankings("activity_count", world.a, now=NOW)
    b = crm_tools.crm_rankings("activity_count", world.b, now=NOW)

    assert [(i["client"]["id"], i["activity_count"]) for i in a["items"]] == [
        (world.rivera, 4), (world.sierra, 3), (world.lucas, 1), (world.delta, 1)]  # empate: "Clínica…" < "Delta…"
    assert [(i["client"]["id"], i["activity_count"]) for i in b["items"]] == [(world.orion, 3), (world.rivera, 2)]


def test_ranking_inactividad(world):
    result = crm_tools.crm_rankings("inactivity", world.a, now=NOW)

    assert [(i["client"]["id"], i["days_inactive"]) for i in result["items"]] == [
        (world.delta, None),   # solo tiene una actividad próxima: nunca ha habido contacto
        (world.rivera, 6), (world.lucas, 1), (world.sierra, 0)]
    assert result["items"][0]["next_activity_datetime"] == "2026-10-12T10:00:00"
    assert result["clients_without_activity"] == 1  # Orion (solo tiene actividad de B)


def test_ranking_facturacion_global(world):
    a = crm_tools.crm_rankings("billing", world.a, now=NOW)
    b = crm_tools.crm_rankings("billing", world.b, now=NOW)

    assert a["scope"] == "global" and a["items"] == b["items"]
    assert [(i["client"]["id"], i["total_billed"]) for i in a["items"]] == [(world.sierra, 3000), (world.rivera, 1500)]


def test_ranking_limite_y_metrica_cerrada(world):
    assert len(crm_tools.crm_rankings("activity_count", world.a, limit=2, now=NOW)["items"]) == 2
    for metric in ["razon_social", "billing; DROP TABLE clients", None]:
        with pytest.raises(ToolArgumentError):
            crm_tools.crm_rankings(metric, world.a)
    with pytest.raises(ToolArgumentError):
        crm_tools.crm_rankings("billing", world.a, limit=21)


# =====================================================================
# Productos
# =====================================================================

def test_catalogo_por_nombre_o_alias_sin_tildes(world):
    by_alias = crm_tools.search_product_catalog("PANTALLA")
    by_name = crm_tools.search_product_catalog("ergonomica")
    everything = crm_tools.search_product_catalog(limit=2)

    assert [p["id"] for p in by_alias["products"]] == [world.monitor]
    assert by_alias["products"][0]["aliases"] == ["pantalla vela"]
    assert [p["id"] for p in by_name["products"]] == [world.silla]
    assert [p["name"] for p in everything["products"]] == ["Lámpara Sin Uso", "Mesa Elevable"]
    assert everything["has_more"] is True
    assert {p["source"] for p in everything["products"]} == {"catalog"}
    assert crm_tools.search_product_catalog("inexistente")["found"] is False


def test_productos_de_cliente_con_evidencia(world):
    result = crm_tools.get_client_products(world.lucas, world.a)

    assert [(p["name"], p["source"]) for p in result["discussed"]] == [
        ("Mesa Elevable", "activity"), ("Monitor Vela 27", "activity")]
    assert result["invoiced"] == []  # tratado no significa comprado
    assert crm_tools.get_client_products(world.lucas, world.b)["discussed"] == []


# =====================================================================
# prepare_meeting_context
# =====================================================================

def test_contexto_de_reunion(world):
    result = crm_tools.prepare_meeting_context(world.rivera, world.a, now=NOW)

    assert result["client"]["id"] == world.rivera
    assert [a["id"] for a in result["recent_activities"]] == [world.ids.a_rivera_past, world.ids.a_rivera_old]
    assert [a["id"] for a in result["upcoming_activities"]] == [world.ids.a_rivera_tomorrow,
                                                                world.ids.a_rivera_later]
    assert result["last_contact_datetime"] == "2026-10-01T10:00:00"
    assert result["billing"]["total_billed"] == 1500
    assert all(s["source"] == "insights.detect_opportunities" for s in result["rule_signals"])
    assert result == crm_tools.prepare_meeting_context(world.rivera, world.a, now=NOW)  # determinista


# =====================================================================
# Propiedades comunes: aislamiento, JSON, solo lectura
# =====================================================================

def _all_tool_results(world, user_id):
    return [
        crm_tools.find_entities("¿Qué sabes de Rivera?", user_id),
        crm_tools.list_activities(user_id, now=NOW),
        crm_tools.list_activities(user_id, client_id=world.rivera, temporal_scope="upcoming", now=NOW),
        crm_tools.list_activities(user_id, contact_id=world.marta_lopez, now=NOW),
        crm_tools.search_activities("visita", user_id, now=NOW),
        crm_tools.search_activities("visita", user_id, client_id=world.rivera, now=NOW),
        crm_tools.get_client_overview(world.rivera, user_id, now=NOW),
        crm_tools.get_contact(world.marta_lopez, user_id, now=NOW),
        *[crm_tools.crm_rankings(metric, user_id, now=NOW) for metric in crm_tools.RANKING_METRICS],
        crm_tools.search_product_catalog(),
        crm_tools.get_client_products(world.rivera, user_id),
        crm_tools.prepare_meeting_context(world.rivera, user_id, now=NOW),
    ]


def test_ninguna_herramienta_mezcla_actividad_de_otro_comercial(world, embeddings):
    for user_id, own, foreign in [(world.a, A_ONLY, B_ONLY), (world.b, B_ONLY, A_ONLY)]:
        dump = json.dumps(_all_tool_results(world, user_id), ensure_ascii=False)
        assert foreign not in dump
        assert own in dump


def test_resultados_json_serializables_y_bd_intacta(world, embeddings, isolated_backend):
    before = hashlib.sha256(isolated_backend.read_bytes()).hexdigest()

    results = _all_tool_results(world, world.a)

    json.dumps(results, allow_nan=False)  # sin sqlite3.Row, numpy ni NaN
    assert hashlib.sha256(isolated_backend.read_bytes()).hexdigest() == before
