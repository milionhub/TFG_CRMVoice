"""
G.3 — Registro de herramientas del chat (services.chat_tools): lista blanca,
validación estricta, salesperson_id inyectado, ids conocidos, recorte de
resultados, errores controlados y estado activo derivado de la traza.
"""
import json
import sqlite3
from types import SimpleNamespace

import pytest

from conftest import CHAT_A_ONLY, CHAT_B_ONLY, CHAT_NOW
from services import chat_tools, crm_tools
from services.chat_tools import Focus, ToolContext, ToolOutcome, derive_state, dispatch, trust_result

EXPECTED_TOOLS = {
    "find_entities", "list_activities", "search_activities", "get_client_overview", "get_contact",
    "crm_rankings", "search_product_catalog", "get_client_products", "prepare_meeting_context",
}


def make_ctx(salesperson_id, *, clients=(), contacts=None, remaining=30.0):
    return ToolContext(salesperson_id=salesperson_id, now=CHAT_NOW, remaining=lambda: remaining,
                       known_clients=set(clients), known_contacts=dict(contacts or {}))


def call(name, args, ctx):
    """Como el orquestador: ejecutar y, si el resultado llega al modelo, confiar en sus ids."""
    outcome = dispatch(name, args if isinstance(args, str) else json.dumps(args), ctx)
    trust_result(outcome, ctx)
    return outcome


# =====================================================================
# Lista blanca y esquemas
# =====================================================================

def test_registro_con_las_nueve_herramientas_de_g2():
    assert set(chat_tools.REGISTRY) == EXPECTED_TOOLS
    assert [s["function"]["name"] for s in chat_tools.TOOL_SCHEMAS] == list(chat_tools.REGISTRY)


def test_esquemas_estrictos_sin_argumentos_de_confianza():
    for schema in chat_tools.TOOL_SCHEMAS:
        function = schema["function"]
        assert function["strict"] is True
        assert function["parameters"]["additionalProperties"] is False
        assert set(function["parameters"]["required"]) == set(function["parameters"]["properties"])
        assert not {"salesperson_id", "now", "timeout"} & set(function["parameters"]["properties"])


def test_herramienta_desconocida(chat_crm):
    for name in ("execute_sql", "__import__", "open_connection", "get_connection", "fetch_activities"):
        outcome = call(name, {}, make_ctx(chat_crm.a))
        assert (outcome.status, outcome.result["ok"]) == ("unknown_tool", False)


# =====================================================================
# Validación de argumentos
# =====================================================================

@pytest.mark.parametrize("name, raw", [
    ("list_activities", "{no es json"),
    ("list_activities", '{"client_id": "1"}'),          # estricto: sin conversión de tipos
    ("list_activities", '{"client_id": 1.0}'),
    ("list_activities", '{"limit": 21}'),
    ("list_activities", '{"temporal_scope": "anteayer"}'),
    ("list_activities", '{"date_from": "2026-13-01"}'),  # lo valida la herramienta de G.2
    ("list_activities", '{"client_id": 0}'),
    ("find_entities", "{}"),
    ("find_entities", '{"client_name": "   "}'),
    ("find_entities", json.dumps({"client_name": "x" * 201})),
    ("search_activities", "{}"),
    ("crm_rankings", '{"metric": "DROP TABLE clients"}'),
    ("get_client_overview", "[1]"),
], ids=lambda v: v if len(v) < 40 else v[:40])
def test_argumentos_mal_formados(chat_crm, name, raw):
    outcome = call(name, raw, make_ctx(chat_crm.a))

    assert outcome.status == "invalid_arguments" and outcome.result["ok"] is False
    assert outcome.focus == Focus()


@pytest.mark.parametrize("extra", [{"salesperson_id": 2}, {"now": "2030-01-01"}, {"sql": "SELECT 1"}])
def test_argumentos_extra_rechazados_sin_ejecutar(chat_crm, monkeypatch, extra):
    called = []
    monkeypatch.setattr(crm_tools, "list_activities", lambda *a, **k: called.append(1))

    outcome = call("list_activities", {"temporal_scope": "past", **extra}, make_ctx(chat_crm.a))

    assert outcome.status == "invalid_arguments"
    assert next(iter(extra)) in outcome.result["message"]
    assert called == []


def test_salesperson_id_lo_inyecta_el_backend(chat_crm, monkeypatch):
    received = []

    def spy(salesperson_id, **kwargs):
        received.append((salesperson_id, kwargs["now"]))
        return {"found": False, "count": 0, "has_more": False, "activities": []}

    monkeypatch.setattr(crm_tools, "list_activities", spy)
    call("list_activities", {"temporal_scope": "tomorrow"}, make_ctx(chat_crm.b))

    assert received == [(chat_crm.b, CHAT_NOW)]


def test_el_error_de_validacion_no_repite_el_valor_recibido(chat_crm):
    outcome = call("find_entities", {"client_name": "x" * 300 + "SECRETO"}, make_ctx(chat_crm.a))
    assert "SECRETO" not in json.dumps(outcome.result)


# =====================================================================
# Ids conocidos
# =====================================================================

def test_id_inventado_se_rechaza(chat_crm, monkeypatch):
    called = []
    monkeypatch.setattr(crm_tools, "get_client_overview", lambda *a, **k: called.append(1))

    for name, args in [("get_client_overview", {"client_id": chat_crm.rivera}),
                       ("list_activities", {"contact_id": chat_crm.marta_lopez}),
                       ("get_contact", {"contact_id": chat_crm.pablo})]:
        outcome = call(name, args, make_ctx(chat_crm.a))
        assert outcome.status == "unknown_id"
        assert "find_entities" in outcome.result["message"]
    assert called == []


def test_ids_resueltos_pasan_a_ser_conocidos(chat_crm):
    ctx = make_ctx(chat_crm.a)

    found = call("find_entities", {"client_name": "Rivera"}, ctx)
    assert found.result["client"]["id"] == chat_crm.rivera and found.result["client"]["status"] == "exact"

    overview = call("get_client_overview", {"client_id": chat_crm.rivera}, ctx)
    assert overview.status == "ok"
    # Los contactos de la ficha también son conocidos, con su cliente
    assert ctx.known_contacts[chat_crm.marta_lopez] == chat_crm.rivera
    assert call("get_contact", {"contact_id": chat_crm.marta_lopez}, ctx).status == "ok"


def test_los_candidatos_ambiguos_no_son_de_confianza(chat_crm):
    ctx = make_ctx(chat_crm.a)

    found = call("find_entities", {"contact_name": "Marta"}, ctx)

    assert found.result["contact"]["status"] == "ambiguous" and found.result["contact"]["id"] is None
    assert {c["name"] for c in found.result["contact"]["candidates"]} == {"Marta López", "Marta Ruiz"}
    assert "id" not in json.dumps(found.result["contact"]["candidates"])
    assert ctx.known_contacts == {} and ctx.known_clients == set()
    assert call("get_contact", {"contact_id": chat_crm.marta_ruiz}, ctx).status == "unknown_id"
    assert found.focus == Focus()


def test_ids_del_estado_activo_son_conocidos(chat_crm):
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera})
    assert call("get_client_products", {"client_id": chat_crm.rivera}, ctx).status == "ok"


# =====================================================================
# Recorte de resultados
# =====================================================================

def test_recorte_de_actividades(chat_crm, factory):
    factory.activity(chat_crm.a, chat_crm.rivera, datetime_iso="2026-10-05T10:00:00",
                     comentario="largo " + "y" * 2000)
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera})

    result = call("list_activities", {"client_id": chat_crm.rivera, "temporal_scope": "past"}, ctx).result

    activity = result["activities"][0]
    assert set(activity) == {"datetime", "timing", "client", "contact", "type", "comment", "products"}
    assert len(activity["comment"]) <= chat_tools.COMMENT_CHARS
    assert "filters" not in result and "now" not in result


def test_recorte_de_ficha_conserva_ambitos(chat_crm):
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera})
    result = call("get_client_overview", {"client_id": chat_crm.rivera}, ctx).result

    assert result["billing"]["scope"] == "global" and result["billing"]["total_billed"] == 600
    assert result["activity"]["scope"] == "salesperson"
    assert not {"cif", "address", "postal_code"} & set(result["client"])


def test_guarda_de_tamano_determinista():
    big = {"ok": True, "items": [{"text": "z" * 100} for _ in range(200)], "other": [1, 2]}

    first = chat_tools.fit_result(json.loads(json.dumps(big)))
    second = chat_tools.fit_result(json.loads(json.dumps(big)))

    assert first == second and first["truncated"] is True
    assert len(json.dumps(first, ensure_ascii=False)) <= chat_tools.MAX_RESULT_CHARS
    assert first["other"] == [1, 2]  # se recorta la lista grande


def test_todos_los_resultados_caben(chat_crm, chat_embeddings):
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera})
    for name, args in [("prepare_meeting_context", {"client_id": chat_crm.rivera}),
                       ("crm_rankings", {"metric": "inactivity"}),
                       ("search_product_catalog", {}),
                       ("search_activities", {"query": "visita"})]:
        outcome = call(name, args, ctx)
        assert outcome.status == "ok", outcome.result
        assert len(json.dumps(outcome.result, ensure_ascii=False)) <= chat_tools.MAX_RESULT_CHARS


# =====================================================================
# Fallos de las herramientas
# =====================================================================

def test_fallo_de_bd_es_un_resultado_controlado(chat_crm, monkeypatch, caplog):
    def broken(*args, **kwargs):
        raise sqlite3.OperationalError("disk I/O error at /secret/path/crm.db")

    monkeypatch.setattr(crm_tools, "crm_rankings", broken)
    outcome = call("crm_rankings", {"metric": "billing"}, make_ctx(chat_crm.a))

    assert outcome.status == "tool_failed"
    assert "secret" not in json.dumps(outcome.result)
    assert "crm_rankings" in caplog.text


def test_busqueda_semantica_un_intento_con_timeout_acotado(chat_crm, chat_embeddings):
    outcome = call("search_activities", {"query": "visita"}, make_ctx(chat_crm.a, remaining=4.0))

    assert outcome.status == "ok"
    assert chat_embeddings.options == [{"max_retries": 0}]
    timeout = chat_embeddings.calls[0]["timeout"]
    # min(6, lo que queda) = 4 s en total, conexión incluida (no se suma a la lectura)
    assert timeout.connect + timeout.read == pytest.approx(4.0)
    assert 0 < timeout.connect <= 2.0 and timeout.read > 0


def test_busqueda_semantica_sin_presupuesto_no_llama_a_openai(chat_crm, chat_embeddings):
    outcome = call("search_activities", {"query": "visita"}, make_ctx(chat_crm.a, remaining=0.5))

    assert outcome.status == "tool_unavailable" and chat_embeddings.calls == []


def test_fallo_de_openai_en_la_busqueda(chat_crm, chat_embeddings):
    chat_embeddings.error = RuntimeError("Incorrect API key provided: sk-test-not-a-real-key")
    outcome = call("search_activities", {"query": "visita"}, make_ctx(chat_crm.a))

    assert outcome.status == "tool_unavailable" and "sk-test" not in json.dumps(outcome.result)


# =====================================================================
# Aislamiento entre comerciales
# =====================================================================

def test_la_evidencia_de_a_nunca_contiene_actividad_de_b(chat_crm, chat_embeddings):
    for user, own, foreign in [(chat_crm.a, CHAT_A_ONLY, CHAT_B_ONLY), (chat_crm.b, CHAT_B_ONLY, CHAT_A_ONLY)]:
        ctx = make_ctx(user, clients={chat_crm.rivera, chat_crm.nebula},
                       contacts={chat_crm.marta_lopez: chat_crm.rivera})
        results = [call(name, args, ctx).result for name, args in [
            ("list_activities", {}),
            ("list_activities", {"contact_id": chat_crm.marta_lopez}),
            ("search_activities", {"query": "visita"}),
            ("get_client_overview", {"client_id": chat_crm.rivera}),
            ("get_contact", {"contact_id": chat_crm.marta_lopez}),
            ("crm_rankings", {"metric": "activity_count"}),
            ("get_client_products", {"client_id": chat_crm.rivera}),
            ("prepare_meeting_context", {"client_id": chat_crm.nebula}),
        ]]
        dump = json.dumps(results, ensure_ascii=False)
        assert all(r["ok"] for r in results)
        assert own in dump and foreign not in dump


# =====================================================================
# Estado activo derivado de la traza
# =====================================================================

def ok(clients=(), contacts=()):
    return ToolOutcome(name="t", status="ok", result={"ok": True}, focus=Focus(tuple(clients), tuple(contacts)))


@pytest.mark.parametrize("client, contact, outcomes, expected", [
    (5, None, [], (5, None)),                                          # sin foco: se conserva
    (None, None, [ok([7])], (7, None)),                                # un cliente → activo
    (5, None, [ok([7]), ok([7])], (7, None)),                          # el mismo dos veces
    (5, None, [ok([7]), ok([8])], (None, None)),                       # comparación → ninguno
    (None, None, [ok(contacts=[(3, 7)])], (7, 3)),                     # el contacto implica su cliente
    (7, (3, 7), [ok([7])], (7, 3)),                                    # mismo cliente: contacto se mantiene
    (7, (3, 7), [ok([8])], (8, None)),                                 # cambio de cliente: fuera contacto
    (7, (3, 7), [ok(contacts=[(4, 7)]), ok(contacts=[(5, 7)])], (7, None)),  # dos contactos
    (7, (3, 7), [ok([8], contacts=[(4, 7)])], (None, None)),           # cliente y contacto incompatibles
    (None, None, [ok(contacts=[(3, None)])], (None, None)),            # contacto sin cliente de confianza
    (7, None, [ok(contacts=[(3, None)])], (7, None)),                  # no se activa ni cambia el cliente
    (5, None, [chat_tools.error_outcome("t", "unknown_id", "x")], (5, None)),
])
def test_derive_state(client, contact, outcomes, expected):
    assert derive_state(client, contact, outcomes) == expected


def test_foco_de_find_entities(chat_crm):
    ctx = make_ctx(chat_crm.a)
    assert call("find_entities", {"client_name": "Rivera"}, ctx).focus == Focus(clients=(chat_crm.rivera,))
    assert call("find_entities", {"contact_name": "Pablo Gil"}, ctx).focus == Focus(
        clients=(chat_crm.nebula,), contacts=((chat_crm.pablo, chat_crm.nebula),))
    assert call("find_entities", {"client_name": "Empresa Inexistente"}, ctx).focus == Focus()
    # Contacto de otro cliente: conflicto, no cambia el contexto
    conflict = call("find_entities", {"client_name": "Rivera", "contact_name": "Pablo Gil"}, ctx)
    assert conflict.result["contact"]["status"] == "conflict" and conflict.focus == Focus()


# =====================================================================
# M3: la relación contacto → cliente no se deduce de una actividad
# =====================================================================

def test_actividad_incoherente_no_establece_el_cliente_del_contacto(chat_crm, factory):
    # Dato incoherente (el alta de actividades no lo impide): Pablo es de Nebula,
    # pero esta actividad de Rivera lo lleva como contacto
    factory.activity(chat_crm.a, chat_crm.rivera, contact_id=chat_crm.pablo, datetime_iso="2026-10-05T10:00:00")
    ctx = make_ctx(chat_crm.a)

    listed = call("list_activities", {"temporal_scope": "past"}, ctx)
    assert listed.status == "ok" and chat_crm.rivera in ctx.known_clients
    assert ctx.known_contacts[chat_crm.pablo] is None        # conocido, pero sin cliente de confianza

    # La consulta normal por ese contacto sigue funcionando...
    by_contact = call("list_activities", {"contact_id": chat_crm.pablo}, ctx)
    assert by_contact.status == "ok" and by_contact.result["count"] == 2  # la incoherente y la de Nebula
    # ...pero no convierte a Rivera en el cliente activo
    assert by_contact.focus == Focus(contacts=((chat_crm.pablo, None),))
    assert derive_state(None, None, [listed, by_contact]) == (None, None)

    # Una fuente que sí establece la relación (get_contact: JOIN con contacts) la fija bien
    contact = call("get_contact", {"contact_id": chat_crm.pablo}, ctx)
    assert ctx.known_contacts[chat_crm.pablo] == chat_crm.nebula
    assert derive_state(None, None, [contact]) == (chat_crm.nebula, chat_crm.pablo)


def test_una_actividad_no_sobrescribe_una_relacion_ya_establecida(chat_crm, factory):
    factory.activity(chat_crm.a, chat_crm.rivera, contact_id=chat_crm.pablo, datetime_iso="2026-10-05T10:00:00")
    ctx = make_ctx(chat_crm.a)

    call("find_entities", {"contact_name": "Pablo Gil"}, ctx)          # Pablo → Nebula
    call("list_activities", {"temporal_scope": "past"}, ctx)           # actividad Rivera + Pablo

    assert ctx.known_contacts[chat_crm.pablo] == chat_crm.nebula


def test_contactos_de_la_ficha_y_de_find_entities_establecen_su_cliente(chat_crm):
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera})
    call("get_client_overview", {"client_id": chat_crm.rivera}, ctx)
    call("find_entities", {"contact_name": "Pablo Gil"}, ctx)

    assert ctx.known_contacts == {chat_crm.marta_lopez: chat_crm.rivera, chat_crm.pablo: chat_crm.nebula}


# =====================================================================
# M4: un conflicto no enseña ids de confianza
# =====================================================================

@pytest.mark.parametrize("client_name, contact_name", [
    ("Empresa Inexistente", "Pablo Gil"),   # cliente dicho que no existe + contacto de otro cliente
    ("Rivera", "Pablo Gil"),                # cliente existente + contacto que no es suyo
], ids=["cliente_inexistente", "contacto_de_otro_cliente"])
def test_conflicto_no_ensena_ids(chat_crm, client_name, contact_name):
    ctx = make_ctx(chat_crm.a)

    found = call("find_entities", {"client_name": client_name, "contact_name": contact_name}, ctx)

    assert "conflict" in (found.result["client"]["status"], found.result["contact"]["status"])
    assert (found.result["client"]["id"], found.result["contact"]["id"], found.result["contact"]["client_id"]) == (
        None, None, None)
    assert found.focus == Focus()
    assert ctx.known_clients == set() and ctx.known_contacts == {}
    # Un uso directo de los ids reales tras el conflicto se rechaza
    assert call("get_contact", {"contact_id": chat_crm.pablo}, ctx).status == "unknown_id"
    for client_id in (chat_crm.nebula, chat_crm.rivera):
        assert call("get_client_overview", {"client_id": client_id}, ctx).status == "unknown_id"

    # Resolverlo sin contradicción sí lo hace utilizable
    call("find_entities", {"contact_name": "Pablo Gil"}, ctx)
    assert call("get_contact", {"contact_id": chat_crm.pablo}, ctx).status == "ok"


# =====================================================================
# G.4 — esquemas, PII, coincidencia parcial, M6 y recorte de listas
# =====================================================================

def _schema(name):
    return next(t["function"] for t in chat_tools.TOOL_SCHEMAS if t["function"]["name"] == name)


def test_esquemas_g4_nuevos_ambitos_metricas_y_producto():
    list_props = _schema("list_activities")["parameters"]["properties"]
    scopes = list_props["temporal_scope"]["anyOf"][0]["enum"]
    assert {"yesterday", "last_week"} <= set(scopes)
    assert "product_name" in list_props and "product_id" not in list_props   # nunca un id de producto
    metrics = _schema("crm_rankings")["parameters"]["properties"]["metric"]["enum"]
    assert {"attention", "product_discussed"} <= set(metrics)
    assert "partial" in _schema("find_entities")["description"]
    test_esquemas_estrictos_sin_argumentos_de_confianza()   # siguen siendo estrictos


def test_ficha_y_reunion_sin_telefono_ni_email_pero_get_contact_si(chat_crm):
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera}, contacts={chat_crm.marta_lopez: chat_crm.rivera})

    overview = call("get_client_overview", {"client_id": chat_crm.rivera}, ctx).result
    meeting = call("prepare_meeting_context", {"client_id": chat_crm.rivera}, ctx).result
    contact = call("get_contact", {"contact_id": chat_crm.marta_lopez}, ctx).result

    assert [set(c) for c in overview["contacts"]] == [{"id", "name", "role"}]
    assert [set(c) for c in meeting["contacts"]] == [{"id", "name", "role"}]
    assert {"phone", "email"} <= set(contact["contact"])


def test_coincidencia_parcial_unica_ensena_el_id_y_la_ambigua_no(factory, user_a):
    costa = factory.client("Diputacion Costa Verde", alias="Costa Verde")
    ctx = make_ctx(user_a["id"])

    unique = call("find_entities", {"client_name": "Costa"}, ctx)
    assert unique.result["client"]["status"] == "partial" and unique.result["client"]["id"] == costa
    assert unique.focus == Focus(clients=(costa,)) and costa in ctx.known_clients
    assert call("get_client_overview", {"client_id": costa}, ctx).status == "ok"

    other = factory.client("Costa Azul Viajes")
    ctx2 = make_ctx(user_a["id"])
    ambiguous = call("find_entities", {"client_name": "Costa"}, ctx2)
    assert ambiguous.result["client"]["status"] == "ambiguous" and ambiguous.result["client"]["id"] is None
    assert ctx2.known_clients == set() and ambiguous.focus == Focus()
    assert call("get_client_overview", {"client_id": other}, ctx2).status == "unknown_id"


def test_contacto_parcial_con_cliente_inexistente_es_conflicto_sin_ids(chat_crm):
    ctx = make_ctx(chat_crm.a)

    found = call("find_entities", {"client_name": "Construcciones", "contact_name": "Gil"}, ctx)

    assert found.result["client"]["status"] == "conflict"
    assert (found.result["client"]["id"], found.result["contact"]["id"]) == (None, None)   # M4: sin ids
    assert found.focus == Focus() and ctx.known_clients == set() and ctx.known_contacts == {}


def test_dispatch_no_confia_en_los_ids_hasta_trust_result(chat_crm):
    ctx = make_ctx(chat_crm.a)

    outcome = dispatch("find_entities", json.dumps({"client_name": "Rivera"}), ctx)
    assert outcome.status == "ok" and ctx.known_clients == set()      # aún no ha llegado al modelo

    trust_result(outcome, ctx)
    assert ctx.known_clients == {chat_crm.rivera}

    failed = chat_tools.error_outcome("find_entities", "evidence_limit", "x")
    trust_result(failed, ctx)                                          # un error nunca enseña ids
    assert ctx.known_clients == {chat_crm.rivera}


def test_listas_con_comentarios_mas_cortos_que_el_detalle(chat_crm, factory):
    long_comment = "largo " + "y" * 2000
    factory.activity(chat_crm.a, chat_crm.rivera, datetime_iso="2026-10-05T10:00:00", comentario=long_comment)
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera})

    listed = call("list_activities", {"client_id": chat_crm.rivera, "temporal_scope": "past"}, ctx).result
    overview = call("get_client_overview", {"client_id": chat_crm.rivera}, ctx).result

    assert len(listed["activities"][0]["comment"]) == chat_tools.LIST_COMMENT_CHARS
    assert len(overview["activity"]["last_activity"]["comment"]) == chat_tools.COMMENT_CHARS


def test_filtro_de_producto_en_el_chat_sin_ids(chat_crm):
    ctx = make_ctx(chat_crm.a)

    resolved = call("list_activities", {"product_name": "Monitor Vela 27"}, ctx).result
    unknown = call("list_activities", {"product_name": "Proyector"}, ctx).result

    assert resolved["product_filter"]["status"] == "resolved" and resolved["count"] == 1
    assert CHAT_B_ONLY not in json.dumps(resolved)
    assert unknown["found"] is False and unknown["product_filter"]["status"] == "unresolved"
    assert "id" not in resolved["product_filter"]


# =====================================================================
# G.4 F1 — conflicto con candidatos parciales: ni ids ni cambio de estado
# =====================================================================

@pytest.fixture
def costas(chat_crm, factory):
    """Dos clientes contienen "Costa"; Raul es de uno de ellos; Pablo Gil, de Nebula (chat_crm)."""
    verde = factory.client("Diputacion Costa Verde", alias="Costa Verde")
    azul = factory.client("Costa Azul Viajes")
    raul = factory.contact(verde, "Raul Navarro")
    return SimpleNamespace(verde=verde, azul=azul, raul=raul)


def test_f1_contacto_no_relacionado_no_ensena_ids_ni_cambia_el_estado(chat_crm, costas):
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera})       # estado activo previo: Rivera

    found = call("find_entities", {"client_name": "Costa", "contact_name": "Pablo Gil"}, ctx)

    assert found.status == "ok" and found.result["client"]["status"] == "conflict"
    assert (found.result["client"]["id"], found.result["contact"]["id"], found.result["contact"]["client_id"]) == (
        None, None, None)
    assert "id" not in json.dumps(found.result["client"]["candidates"])
    assert found.focus == Focus()
    assert ctx.known_clients == {chat_crm.rivera} and ctx.known_contacts == {}
    assert derive_state(chat_crm.rivera, None, [found]) == (chat_crm.rivera, None)
    for name, args in [("get_contact", {"contact_id": chat_crm.pablo}),
                       ("get_client_overview", {"client_id": chat_crm.nebula}),
                       ("get_client_overview", {"client_id": costas.verde})]:
        assert call(name, args, ctx).status == "unknown_id"


def test_f1_contacto_compatible_puede_enfocar_su_cliente(chat_crm, costas):
    ctx = make_ctx(chat_crm.a)

    found = call("find_entities", {"client_name": "Costa", "contact_name": "Raul"}, ctx)

    assert found.result["client"]["status"] == "partial" and found.result["client"]["id"] == costas.verde
    assert found.focus == Focus(clients=(costas.verde,), contacts=((costas.raul, costas.verde),))
    assert ctx.known_contacts == {costas.raul: costas.verde} and costas.verde in ctx.known_clients
    assert derive_state(None, None, [found]) == (costas.verde, costas.raul)


def test_f1_sin_contacto_ambiguo_sin_ids(chat_crm, costas):
    ctx = make_ctx(chat_crm.a)

    found = call("find_entities", {"client_name": "Costa"}, ctx)

    assert found.result["client"]["status"] == "ambiguous" and found.result["client"]["id"] is None
    assert set(found.result["client"]["candidates"]) == {"Costa Azul Viajes", "Diputacion Costa Verde"}
    assert ctx.known_clients == set() and found.focus == Focus()


# =====================================================================
# G.4 — guarda de alcance: el contexto activo no estrecha una consulta de
# actividades si el mensaje no se refiere a él
# =====================================================================

def scoped_ctx(chat_crm, scope):
    ctx = make_ctx(chat_crm.a, clients={chat_crm.rivera})
    ctx.active_client_id, ctx.active_label, ctx.scope = chat_crm.rivera, "Rivera Industrial S.L.", scope
    return ctx


def test_alcance_ambiguo_no_ejecuta_ni_ensena_nada(chat_crm, monkeypatch):
    executed = []
    monkeypatch.setattr(crm_tools, "list_activities", lambda *a, **k: executed.append(1))
    ctx = scoped_ctx(chat_crm, None)

    outcome = call("list_activities", {"client_id": chat_crm.rivera, "temporal_scope": "last_week"}, ctx)

    assert outcome.status == "scope_ambiguous" and executed == []
    assert "¿Te refieres a Rivera Industrial S.L. o a todas tus actividades?" in outcome.result["message"]
    assert outcome.focus == Focus() and ctx.known_clients == {chat_crm.rivera}
    assert derive_state(chat_crm.rivera, None, [outcome]) == (chat_crm.rivera, None)


def test_alcance_global_rechaza_el_filtro_del_contexto(chat_crm):
    outcome = call("search_activities", {"query": "visita", "client_id": chat_crm.rivera}, scoped_ctx(chat_crm, "global"))
    assert outcome.status == "scope_global" and "sin client_id" in outcome.result["message"]


def test_referencia_contextual_permite_el_filtro(chat_crm):
    outcome = call("list_activities", {"client_id": chat_crm.rivera, "temporal_scope": "past"},
                   scoped_ctx(chat_crm, "contextual"))
    assert outcome.status == "ok" and outcome.result["count"] == 1


def test_sin_filtro_o_con_entidad_resuelta_en_el_turno_no_hay_guarda(chat_crm):
    ctx = scoped_ctx(chat_crm, None)
    assert call("list_activities", {"temporal_scope": "past"}, ctx).status == "ok"      # global: sin filtro
    call("find_entities", {"client_name": "Rivera"}, ctx)                              # nombrado en este turno
    assert call("list_activities", {"client_id": chat_crm.rivera, "temporal_scope": "past"}, ctx).status == "ok"


def test_herramientas_de_un_cliente_no_llevan_guarda(chat_crm):
    # "¿Y sus productos?" o una ficha necesitan un cliente: no hay alternativa global que confundir
    ctx = scoped_ctx(chat_crm, None)
    assert call("get_client_products", {"client_id": chat_crm.rivera}, ctx).status == "ok"
    assert call("get_client_overview", {"client_id": chat_crm.rivera}, ctx).status == "ok"


# =====================================================================
# G.6: find_entities solo identifica (el modelo leía "candidates" vacío como
# "el cliente no tiene contactos" y negaba actividades y facturación)
# =====================================================================

def test_find_entities_solo_identifica(chat_crm):
    ctx = make_ctx(chat_crm.a)

    found = call("find_entities", {"client_name": "Rivera"}, ctx)

    assert found.result["client"]["id"] == chat_crm.rivera
    assert found.result["note"] == chat_tools.FIND_ENTITIES_NOTE
    assert "contact.candidates vacío NO significa que no tenga contactos" in found.result["note"]
    schema = next(s for s in chat_tools.TOOL_SCHEMAS if s["function"]["name"] == "find_entities")
    assert "Solo identifica" in schema["function"]["description"]
