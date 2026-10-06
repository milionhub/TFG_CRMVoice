"""
G.2 — Herramientas CRM de solo lectura (services.crm_tools).

Escenario fijo: NOW = miércoles 2026-10-07 12:00 (semana: lunes 05 a
domingo 11). Dos comerciales con actividades marcadas (A_ONLY / B_ONLY)
para comprobar que ninguna herramienta mezcla actividad privada. Catálogo
y facturación son globales por diseño.
"""
import hashlib
import json
import sqlite3
from datetime import datetime
from types import SimpleNamespace

import pytest

import db
from services import crm_tools, semantic_search_service
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

def test_find_entities_cliente_por_nombre(world):
    result = crm_tools.find_entities(world.a, client_name="Rivera")

    assert result["found"] is True
    assert (result["client"]["id"], result["client"]["name"], result["client"]["mention"],
            result["client"]["status"]) == (world.rivera, "Rivera Industrial S.L.", "Rivera", "exact")
    assert result["contact"]["id"] is None and result["contact"]["mention"] is None


def test_find_entities_contacto_hereda_su_cliente(world):
    result = crm_tools.find_entities(world.a, contact_name="Marta López")

    assert result["contact"]["id"] == world.marta_lopez
    assert result["contact"]["client_id"] == world.rivera and result["contact"]["status"] == "exact"
    assert result["client"]["id"] == world.rivera
    assert result["client"]["status"] == "inherited" and result["client"]["origin"] == "inherited"


def test_find_entities_ambiguo_no_elige(world):
    result = crm_tools.find_entities(world.a, contact_name="Marta")

    assert result["found"] is False
    assert result["contact"]["status"] == "ambiguous" and result["contact"]["id"] is None
    assert {(c["id"], c["client_id"]) for c in result["contact"]["candidates"]} == {
        (world.marta_lopez, world.rivera), (world.marta_ruiz, world.sierra)}


def test_find_entities_contacto_de_otro_cliente_es_conflicto(world):
    result = crm_tools.find_entities(world.a, client_name="Rivera", contact_name="Marta Ruiz")

    assert result["client"]["id"] == world.rivera
    assert result["contact"]["status"] == "conflict" and result["contact"]["id"] is None
    assert [c["client_name"] for c in result["contact"]["candidates"]] == ["Sierra Norte S.A."]


def test_find_entities_sin_coincidencias(world):
    result = crm_tools.find_entities(world.a, client_name="Zeta Global")

    assert result["found"] is False
    assert result["client"]["status"] == "unresolved" and result["client"]["id"] is None


@pytest.mark.parametrize("kwargs", [
    {},
    {"client_name": "   "},
    {"contact_name": "x" * 501},
])
def test_find_entities_argumentos_invalidos(world, kwargs):
    with pytest.raises(ToolArgumentError):
        crm_tools.find_entities(world.a, **kwargs)


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
        "scope": "global", "source": result["billing"]["source"],
        "total_billed": 1500, "invoice_count": 2, "average_ticket": 750.0,
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
        crm_tools.find_entities(user_id, client_name="Rivera"),
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


# =====================================================================
# G.3: solo lectura a nivel de BD y timeout del embedding para el chat
# =====================================================================

def test_la_conexion_de_las_herramientas_rechaza_escrituras(world):
    from services.crm_tools._common import open_connection

    with open_connection() as conn:
        with pytest.raises(sqlite3.OperationalError, match="readonly"):
            conn.execute("INSERT INTO clients (razon_social) VALUES ('Escritura prohibida')")
        assert conn.execute("SELECT COUNT(*) FROM clients").fetchone()[0] == 5  # leer sí

    # Solo esa conexión: el resto de la aplicación sigue pudiendo escribir
    conn = db.get_connection()
    try:
        assert conn.execute("PRAGMA query_only").fetchone()[0] == 0
    finally:
        conn.close()


def test_busqueda_semantica_con_timeout_un_solo_intento(world, monkeypatch):
    calls, options = [], []

    def create(**kwargs):
        calls.append(kwargs)
        return SimpleNamespace(data=[SimpleNamespace(embedding=[1.0, 0.0, 0.0])])

    single_attempt = SimpleNamespace(embeddings=SimpleNamespace(create=create))

    def with_options(**kwargs):
        options.append(kwargs)
        return single_attempt

    monkeypatch.setattr(semantic_search_service, "client", SimpleNamespace(with_options=with_options))

    result = crm_tools.search_activities("visita", world.a, timeout=4.5, now=NOW)

    assert result["found"] is True
    assert options == [{"max_retries": 0}]
    assert [{k: v for k, v in c.items() if k != "timeout"} for c in calls] == [
        {"model": "text-embedding-3-small", "input": "visita"}]
    timeout = calls[0]["timeout"]
    # 4.5 s en total: conexión acotada (min(2, total/3)) y el resto para leer, sin sumarse
    assert (timeout.connect, timeout.read) == (1.5, 3.0)
    assert timeout.connect + timeout.read == 4.5


# =====================================================================
# G.4 — ámbitos yesterday / last_week (intervalos semiabiertos por día)
# =====================================================================

@pytest.fixture
def dated(factory, user_a, user_b):
    client = factory.client("Fechas Prueba S.L.")
    times = ["2026-09-27T23:59:59", "2026-09-28T00:00:00", "2026-10-03T23:59:59", "2026-10-04T00:00:00",
             "2026-10-04T23:59:59.999", "2026-10-05T00:00:00", "2026-10-10T12:00:00", "2026-10-11T23:59:59"]
    for t in times:
        factory.activity(user_a["id"], client, datetime_iso=t, comentario=f"{A_ONLY} {t}")
    factory.activity(user_b["id"], client, datetime_iso="2026-10-04T10:00:00", comentario=f"{B_ONLY} ayer")
    return SimpleNamespace(a=user_a["id"])


def _times(result):
    return [a["datetime"] for a in result["activities"]]


def test_yesterday_y_last_week_desde_un_lunes_a_medianoche(dated):
    monday_midnight = datetime(2026, 10, 5, 0, 0)

    yesterday = crm_tools.list_activities(dated.a, temporal_scope="yesterday", now=monday_midnight)
    assert _times(yesterday) == ["2026-10-04T00:00:00", "2026-10-04T23:59:59.999"]   # domingo entero, con ms
    assert B_ONLY not in json.dumps(yesterday)

    last_week = crm_tools.list_activities(dated.a, temporal_scope="last_week", now=monday_midnight)
    assert _times(last_week) == ["2026-09-28T00:00:00", "2026-10-03T23:59:59", "2026-10-04T00:00:00",
                                 "2026-10-04T23:59:59.999"]                       # lunes 28 a domingo 4
    assert last_week["order"] == "asc"


def test_last_week_desde_el_domingo_por_la_noche_es_la_misma_semana_anterior(dated):
    sunday_night = datetime(2026, 10, 11, 23, 59, 59)

    last_week = crm_tools.list_activities(dated.a, temporal_scope="last_week", now=sunday_night)
    yesterday = crm_tools.list_activities(dated.a, temporal_scope="yesterday", now=sunday_night)

    assert _times(last_week)[0] == "2026-09-28T00:00:00" and _times(last_week)[-1] == "2026-10-04T23:59:59.999"
    assert _times(yesterday) == ["2026-10-10T12:00:00"]


def test_ambitos_existentes_sin_cambios(dated):
    now = datetime(2026, 10, 5, 0, 0)
    assert _times(crm_tools.list_activities(dated.a, temporal_scope="today", now=now)) == ["2026-10-05T00:00:00"]
    assert "yesterday" in crm_tools.TEMPORAL_SCOPES and "last_week" in crm_tools.TEMPORAL_SCOPES
    with pytest.raises(ToolArgumentError):
        crm_tools.list_activities(dated.a, temporal_scope="anteayer", now=now)


# =====================================================================
# G.4 — coincidencia parcial por palabras completas (solo find_entities)
# =====================================================================

@pytest.fixture
def partial_catalog(factory):
    ids = {
        "costa": factory.client("Diputacion Costa Verde", alias="Costa Verde"),
        "sierra": factory.client("Grupo Sierra Norte SL", alias="Sierra Norte"),
        "valle": factory.client("Ayuntamiento de Valle Alto", alias="Valle Alto"),
        "lucas": factory.client("Instituto San Lucas", alias="San Lucas"),
        "rivera": factory.client("Tecnologia Rivera SL", alias="Rivera"),
    }
    ids["ruiz"] = factory.contact(ids["lucas"], "Carlos Ruiz")
    ids["perez"] = factory.contact(ids["rivera"], "Carlos Perez")
    ids["raul"] = factory.contact(ids["costa"], "Raul Navarro")
    return ids


@pytest.mark.parametrize("mention, key", [
    ("Costa", "costa"), ("Sierra", "sierra"), ("Valle", "valle"), ("VALLE", "valle"), ("válle", "valle"),
])
def test_coincidencia_parcial_unica_resuelve(partial_catalog, mention, key):
    result = crm_tools.find_entities(1, client_name=mention)

    assert result["found"] is True
    assert (result["client"]["id"], result["client"]["status"]) == (partial_catalog[key], "partial")


def test_coincidencia_parcial_ambigua_no_elige(partial_catalog, factory):
    factory.client("Costa Azul Viajes")

    result = crm_tools.find_entities(1, client_name="Costa")

    assert result["found"] is False and result["client"]["id"] is None
    assert result["client"]["status"] == "ambiguous"
    assert {c["name"] for c in result["client"]["candidates"]} == {"Costa Azul Viajes", "Diputacion Costa Verde"}


@pytest.mark.parametrize("mention", ["Construcciones", "de", "SL", "Costa Brava"])
def test_sin_coincidencia_sigue_sin_resolver(partial_catalog, mention):
    result = crm_tools.find_entities(1, client_name=mention)
    assert result["found"] is False and result["client"]["status"] == "unresolved"


def test_contacto_parcial_y_dentro_del_cliente(partial_catalog):
    by_surname = crm_tools.find_entities(1, contact_name="Ruiz")
    assert by_surname["contact"]["id"] == partial_catalog["ruiz"] and by_surname["contact"]["status"] == "partial"
    assert by_surname["client"]["id"] == partial_catalog["lucas"] and by_surname["client"]["status"] == "inherited"

    # Cliente parcial + contacto: el contacto se resuelve dentro de ese cliente (lógica de la Fase F)
    scoped = crm_tools.find_entities(1, client_name="Costa", contact_name="Raul")
    assert scoped["client"]["status"] == "partial" and scoped["contact"]["id"] == partial_catalog["raul"]

    # Cliente dicho que no existe + contacto (parcial) de otro cliente: conflicto, como en la Fase F
    conflict = crm_tools.find_entities(1, client_name="Construcciones", contact_name="Ruiz")
    assert conflict["client"]["status"] == "conflict" and conflict["client"]["id"] is None
    assert conflict["contact"]["status"] == "partial"

    # "Carlos" sigue siendo ambiguo: dos contactos lo contienen
    carlos = crm_tools.find_entities(1, contact_name="Carlos")
    assert carlos["contact"]["status"] == "ambiguous" and carlos["contact"]["id"] is None


def test_el_resolvedor_base_no_cambia(partial_catalog):
    from services.entity_resolver import resolve_client_and_contact

    # La coincidencia parcial es solo de la herramienta del chat: el resolvedor base sigue igual
    assert resolve_client_and_contact("Costa", None)["client"]["status"] == "unresolved"


# =====================================================================
# G.4 — métrica attention
# =====================================================================

ATT_NOW = datetime(2026, 10, 7, 12, 0)


@pytest.fixture
def attention_world(factory, user_a, user_b):
    a, b = user_a["id"], user_b["id"]
    c = {name: factory.client(name) for name in
         ["Alfa Activo", "Beta Inactivo", "Gamma Nunca", "Delta Solo B", "Epsilon Sin Factura"]}
    # Alfa: actividad pasada reciente y una próxima (A)
    factory.activity(a, c["Alfa Activo"], datetime_iso="2026-09-27T10:00:00", comentario=A_ONLY)
    factory.activity(a, c["Alfa Activo"], datetime_iso="2026-10-20T10:00:00", comentario=A_ONLY)
    # Beta: la última actividad de A fue hace 120 días
    factory.activity(a, c["Beta Inactivo"], datetime_iso="2026-06-09T10:00:00", comentario=A_ONLY)
    # Delta: solo B tiene actividad (reciente y próxima); para A, "nunca contactado"
    factory.activity(b, c["Delta Solo B"], datetime_iso="2026-10-06T10:00:00", comentario=B_ONLY)
    factory.activity(b, c["Delta Solo B"], datetime_iso="2026-10-30T10:00:00", comentario=B_ONLY)
    # Epsilon: A tuvo actividad hace 30 días
    factory.activity(a, c["Epsilon Sin Factura"], datetime_iso="2026-09-07T10:00:00", comentario=A_ONLY)

    conn = db.get_connection()
    # Facturación GLOBAL (sin propietario): 4 clientes con facturación > 0 → tercio superior = 2
    for name, total in [("Gamma Nunca", 9000), ("Beta Inactivo", 8000), ("Delta Solo B", 3000), ("Alfa Activo", 1000)]:
        invoice = conn.execute("INSERT INTO invoices (fecha, client_id) VALUES ('2026-05-01', ?)", (c[name],)).lastrowid
        conn.execute("INSERT INTO invoice_lines (invoice_id, cantidad, precio, total) VALUES (?, 1, ?, ?)",
                     (invoice, total, total))
    conn.commit()
    conn.close()
    return SimpleNamespace(a=a, b=b, c=c)


def _attention(world, user, limit=10):
    return crm_tools.crm_rankings("attention", user, limit=limit, now=ATT_NOW)


def test_attention_senales_y_universo_completo(attention_world):
    result = _attention(attention_world, attention_world.a)
    by_name = {i["client"]["name"]: i for i in result["items"]}

    assert result["clients_considered"] == 5 and set(by_name) == set(attention_world.c)
    assert result["scope"] == {"activity": "salesperson", "billing": "global"}
    assert "no una puntuación" in result["rules"] and "90 días" in result["rules"]

    assert by_name["Gamma Nunca"]["signals"] == ["never_contacted", "no_upcoming", "top_billing",
                                                 "top_billing_low_attention"]
    assert by_name["Beta Inactivo"]["signals"] == ["inactive_90d", "no_upcoming", "top_billing",
                                                   "top_billing_low_attention"]
    assert by_name["Beta Inactivo"]["days_since_last_activity"] == 120
    assert by_name["Delta Solo B"]["signals"] == ["never_contacted", "no_upcoming"]   # lo de B no cuenta
    assert by_name["Epsilon Sin Factura"]["signals"] == ["no_upcoming"]
    assert by_name["Alfa Activo"]["signals"] == []
    assert by_name["Alfa Activo"]["next_activity_datetime"] == "2026-10-20T10:00:00"
    assert by_name["Alfa Activo"]["activities_last_90_days"] == 1     # la próxima no cuenta como reciente
    assert by_name["Epsilon Sin Factura"]["total_billed"] == 0 and by_name["Gamma Nunca"]["total_billed"] == 9000


def test_attention_orden_determinista_y_limite(attention_world):
    names = [i["client"]["name"] for i in _attention(attention_world, attention_world.a)["items"]]
    # 4 señales (nunca contactado antes que 120 días), después 2, 1 y 0
    assert names == ["Gamma Nunca", "Beta Inactivo", "Delta Solo B", "Epsilon Sin Factura", "Alfa Activo"]

    limited = _attention(attention_world, attention_world.a, limit=2)
    assert [i["client"]["name"] for i in limited["items"]] == names[:2]
    assert limited["clients_considered"] == 5


def test_attention_aislada_por_comercial_y_facturacion_global(attention_world):
    for_b = {i["client"]["name"]: i for i in _attention(attention_world, attention_world.b)["items"]}
    for_a = {i["client"]["name"]: i for i in _attention(attention_world, attention_world.a)["items"]}

    # B sí tiene Delta (reciente y próxima); para B, Alfa nunca se ha contactado
    assert for_b["Delta Solo B"]["signals"] == []
    assert "never_contacted" in for_b["Alfa Activo"]["signals"]
    # La facturación es la misma para los dos (global)
    assert {n: i["total_billed"] for n, i in for_a.items()} == {n: i["total_billed"] for n, i in for_b.items()}

    dump_a = json.dumps(_attention(attention_world, attention_world.a))
    assert "2026-10-06" not in dump_a and "2026-10-30" not in dump_a     # fechas de B


def test_attention_las_actividades_de_b_no_cambian_lo_de_a(attention_world, factory):
    before = _attention(attention_world, attention_world.a)
    factory.activity(attention_world.b, attention_world.c["Gamma Nunca"], datetime_iso="2026-10-06T09:00:00",
                     comentario=B_ONLY)
    factory.activity(attention_world.b, attention_world.c["Beta Inactivo"], datetime_iso="2026-11-01T09:00:00",
                     comentario=B_ONLY)

    assert _attention(attention_world, attention_world.a) == before


# =====================================================================
# G.4 — product_discussed y filtro product_name
# =====================================================================

def test_product_discussed_solo_con_actividad_propia(world):
    for_a = crm_tools.crm_rankings("product_discussed", world.a, limit=10, now=NOW)
    for_b = crm_tools.crm_rankings("product_discussed", world.b, limit=10, now=NOW)

    assert for_a["scope"] == "salesperson"
    assert [(i["product"]["name"], i["activity_count"], i["client_count"]) for i in for_a["items"]] == [
        ("Monitor Vela 27", 2, 2), ("Mesa Elevable", 1, 1), ("Silla Ergonómica", 1, 1)]
    assert [(i["product"]["name"], i["activity_count"]) for i in for_b["items"]] == [("Mesa Elevable", 1)]
    assert '"id"' not in json.dumps(for_a["items"])


def test_filtro_por_producto_exacto_alias_y_aislado(world):
    exact = crm_tools.list_activities(world.a, product_name="monitor vela 27", now=NOW)
    alias = crm_tools.list_activities(world.a, product_name="Pantalla Vela", now=NOW)

    assert exact["product_filter"] == {
        "query": "monitor vela 27", "status": "resolved", "product": "Monitor Vela 27", "candidates": [],
        "by_client": [  # TODAS las de A con el producto, agrupadas por cliente (2 clientes, 1 cada uno)
            {"client": {"id": world.lucas, "name": "Clínica San Lucas S.L."}, "activity_count": 1,
             "last_activity_datetime": "2026-10-06T11:00:00"},
            {"client": {"id": world.rivera, "name": "Rivera Industrial S.L."}, "activity_count": 1,
             "last_activity_datetime": "2026-10-01T10:00:00"}]}
    assert sorted(a["id"] for a in exact["activities"]) == sorted([world.ids.a_rivera_past, world.ids.a_lucas])
    assert [a["id"] for a in alias["activities"]] == [a["id"] for a in exact["activities"]]

    # Mesa: A la trató con San Lucas; B, con Rivera. Cada uno ve solo lo suyo
    mesa_a = crm_tools.list_activities(world.a, product_name="Mesa Elevable", now=NOW)
    mesa_b = crm_tools.list_activities(world.b, product_name="Mesa Elevable", now=NOW)
    assert [a["id"] for a in mesa_a["activities"]] == [world.ids.a_lucas]
    assert [a["id"] for a in mesa_b["activities"]] == [world.ids.b_rivera_tomorrow]


def test_filtro_por_producto_combinado_con_cliente_y_fechas(world):
    by_client = crm_tools.list_activities(world.a, product_name="Monitor Vela 27", client_id=world.rivera, now=NOW)
    in_range = crm_tools.list_activities(world.a, product_name="Monitor Vela 27", date_from="2026-10-05",
                                         date_to="2026-10-06", now=NOW)

    assert [a["id"] for a in by_client["activities"]] == [world.ids.a_rivera_past]
    assert [a["id"] for a in in_range["activities"]] == [world.ids.a_lucas]


def test_producto_ambiguo_o_desconocido_no_se_adivina(world, factory):
    factory.product("Monitor Vela 32", 400)

    ambiguous = crm_tools.list_activities(world.a, product_name="vela", now=NOW)
    unknown = crm_tools.list_activities(world.a, product_name="Proyector Láser", now=NOW)

    assert ambiguous["found"] is False and ambiguous["activities"] == []
    assert ambiguous["product_filter"]["status"] == "ambiguous"
    assert set(ambiguous["product_filter"]["candidates"]) == {"Monitor Vela 27", "Monitor Vela 32"}
    assert unknown["found"] is False and unknown["product_filter"] == {
        "query": "Proyector Láser", "status": "unresolved", "product": None, "candidates": []}
    with pytest.raises(ToolArgumentError):
        crm_tools.list_activities(world.a, product_name="  ", now=NOW)
    assert crm_tools.list_activities(world.a, product_name="¡¿!?", now=NOW)["product_filter"]["status"] == "unresolved"


# =====================================================================
# G.4 F1 — la coincidencia parcial no puede deshacer un conflicto de la Fase F
# =====================================================================

@pytest.fixture
def two_costas(partial_catalog, factory):
    """Dos clientes contienen "Costa"; Pablo Gil es de un tercero (Nebula)."""
    ids = dict(partial_catalog)
    ids["costa_azul"] = factory.client("Costa Azul Viajes")
    ids["nebula"] = factory.client("Nebula Logistica", alias="Nebula")
    ids["pablo"] = factory.contact(ids["nebula"], "Pablo Gil")
    return ids


def test_f1_contacto_de_otro_cliente_mantiene_el_conflicto(two_costas):
    from services.entity_resolver import resolve_client_and_contact

    assert resolve_client_and_contact("Costa", "Pablo Gil")["client"]["status"] == "conflict"   # Fase F

    result = crm_tools.find_entities(1, client_name="Costa", contact_name="Pablo Gil")

    assert result["client"]["status"] == "conflict" and result["client"]["id"] is None
    # Los candidatos parciales quedan para aclarar, pero ninguno es el cliente del contacto
    assert {c["name"] for c in result["client"]["candidates"]} == {"Costa Azul Viajes", "Diputacion Costa Verde"}
    assert two_costas["nebula"] not in [c["id"] for c in result["client"]["candidates"]]


def test_f1_contacto_compatible_deshace_la_ambiguedad(two_costas):
    result = crm_tools.find_entities(1, client_name="Costa", contact_name="Raul")

    assert (result["client"]["status"], result["client"]["id"]) == ("partial", two_costas["costa"])
    assert result["client"]["candidates"] == [{"id": two_costas["costa"], "name": "Diputacion Costa Verde",
                                               "score": 0.0}]
    assert result["contact"]["id"] == two_costas["raul"] and result["contact"]["client_id"] == two_costas["costa"]


def test_f1_sin_contacto_sigue_ambiguo(two_costas):
    result = crm_tools.find_entities(1, client_name=" Costa ")

    assert (result["client"]["status"], result["client"]["id"]) == ("ambiguous", None)
    assert {c["name"] for c in result["client"]["candidates"]} == {"Costa Azul Viajes", "Diputacion Costa Verde"}
    assert result["contact"]["id"] is None
