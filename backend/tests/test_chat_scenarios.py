"""
G.4 — Conversaciones realistas de principio a fin por POST /chat.

Todo es real salvo el modelo: SQLite temporal con un catálogo como el de
desarrollo, herramientas del CRM, resolvedor de entidades, persistencia y
estado activo. El modelo es un ScriptedModel (decide qué herramientas pide);
lo que se comprueba son las fronteras del backend: traza, argumentos, ids de
confianza, estado guardado, aislamiento entre comerciales y límites.

Ahora fijo: miércoles 2026-10-07 12:00 (semana pasada: 28/09 a 04/10;
mañana: 08/10).
"""
import json
from types import SimpleNamespace

import pytest

import db
from conftest import CHAT_NOW
from services import chat as chat_service
from services import chat_orchestrator

A_MARK = "SCN_A_ONLY_51C2"
B_MARK = "SCN_B_ONLY_93E7"


@pytest.fixture(autouse=True)
def fixed_now(monkeypatch):
    monkeypatch.setattr(chat_service, "current_time", lambda: CHAT_NOW)


@pytest.fixture
def crm(factory, user_a, user_b):
    c = {alias: factory.client(name, alias=alias) for name, alias in [
        ("Tecnologia Rivera SL", "Rivera"), ("Grupo Sierra Norte SL", "Sierra Norte"),
        ("Ayuntamiento de Valle Alto", "Valle Alto"), ("Diputacion Costa Verde", "Costa Verde"),
        ("Instituto San Lucas", "San Lucas"), ("Colegio Nuevo Horizonte", "Nuevo Horizonte")]}
    ct = {
        "perez": factory.contact(c["Rivera"], "Carlos Perez"),
        "ruiz": factory.contact(c["San Lucas"], "Carlos Ruiz"),
        "raul": factory.contact(c["Costa Verde"], "Raul Navarro"),
    }
    monitor = factory.product("Monitor Mar 24", 189)
    a, b = user_a["id"], user_b["id"]

    def act(owner, client, when, *, contact=None, products=()):
        mark = A_MARK if owner == a else B_MARK
        return factory.activity(owner, c[client], contact_id=contact, datetime_iso=when,
                                comentario=f"{mark} {client} {when}", products=[(p, "raw") for p in products],
                                embedding=[1.0, 0.0, 0.0])

    act(a, "Costa Verde", "2026-09-15T10:00:00", products=[monitor])
    act(a, "Costa Verde", "2026-06-01T10:00:00")
    act(a, "Rivera", "2026-09-30T09:00:00")                              # semana pasada
    act(a, "San Lucas", "2026-10-02T16:00:00.000", contact=ct["ruiz"])   # semana pasada, con ms
    act(a, "Rivera", "2026-10-08T09:30:00", contact=ct["perez"])         # mañana
    act(a, "San Lucas", "2026-10-08T16:00:00")                           # mañana
    act(a, "Sierra Norte", "2026-05-01T10:00:00")                        # hace más de 90 días
    act(b, "Valle Alto", "2026-10-06T10:00:00")
    act(b, "Costa Verde", "2026-10-01T11:00:00", products=[monitor])     # semana pasada, pero de B
    act(b, "Valle Alto", "2026-10-08T12:00:00")

    conn = db.get_connection()
    for alias, total in [("San Lucas", 42000), ("Nuevo Horizonte", 37000), ("Valle Alto", 32000),
                         ("Costa Verde", 23000), ("Sierra Norte", 15000), ("Rivera", 14000)]:
        invoice = conn.execute("INSERT INTO invoices (fecha, client_id) VALUES ('2026-03-01', ?)",
                               (c[alias],)).lastrowid
        conn.execute("INSERT INTO invoice_lines (invoice_id, cantidad, precio, total) VALUES (?, 1, ?, ?)",
                     (invoice, total, total))
    conn.commit()
    conn.close()
    return SimpleNamespace(a=a, b=b, c=c, ct=ct)


# --- utilidades -----------------------------------------------------------

def ask(client, user, message, conversation_id=None):
    body = {"message": message}
    if conversation_id is not None:
        body["conversation_id"] = conversation_id
    response = client.post("/chat", json=body, headers=user["headers"])
    assert response.status_code == 200, response.text
    return response.json()


def tool_results(request):
    return [json.loads(m["content"]) for m in request["messages"] if m["role"] == "tool"]


def last_result(request):
    return tool_results(request)[-1]


def trace(dbq, conversation_id):
    """Herramientas guardadas en el último turno del asistente: [(nombre, args, estado)]."""
    rows = dbq.all("SELECT metadata FROM chat_messages WHERE conversation_id = ? AND role = 'assistant' "
                   "ORDER BY id DESC LIMIT 1", (conversation_id,))
    return [(t["name"], t["args"], t["status"]) for t in json.loads(rows[0]["metadata"])["tools"]]


def state_of(request):
    return json.loads(request["messages"][1]["content"].split("\n", 1)[1])


def bounded(model, start):
    """Cada turno respeta los límites del orquestador."""
    turn = model.requests[start:]
    assert len(turn) <= chat_orchestrator.MAX_MODEL_CALLS
    # La última petición del turno lleva todos los resultados de herramientas del turno
    assert len(tool_results(turn[-1])) <= chat_orchestrator.MAX_TOOL_CALLS_PER_REQUEST


def found_client_id(request):
    return last_result(request)["client"]["id"]


# =====================================================================
# 1. Alias parcial → ficha → estado activo → seguimiento
# =====================================================================

def test_costa_parcial_ficha_y_seguimiento(client, user_a, crm, model, dbq):
    model.script([("find_entities", {"client_name": "Costa"})],
                 lambda r: [("get_client_overview", {"client_id": found_client_id(r)})],
                 "He entendido 'Costa' como Diputacion Costa Verde. Va bien.")
    first = ask(client, user_a, "¿Cómo va Costa?")
    cid = first["conversation_id"]

    found = tool_results(model.requests[1])[0]
    assert (found["client"]["status"], found["client"]["id"]) == ("partial", crm.c["Costa Verde"])
    assert trace(dbq, cid) == [("find_entities", {"client_name": "Costa"}, "ok"),
                               ("get_client_overview", {"client_id": crm.c["Costa Verde"]}, "ok")]
    assert first["metadata"]["active_client"] == {"id": crm.c["Costa Verde"], "name": "Diputacion Costa Verde"}

    start = len(model.requests)
    model.script([("list_activities", {"client_id": crm.c["Costa Verde"], "temporal_scope": "past", "limit": 1})],
                 "Tu última actividad con Diputacion Costa Verde fue el 15 de septiembre de 2026.")
    second = ask(client, user_a, "¿Y su última actividad?", cid)

    latest = last_result(model.requests[-1])
    assert [a["datetime"] for a in latest["activities"]] == ["2026-09-15T10:00:00"]   # la del 01/10 es de B
    assert B_MARK not in json.dumps(latest)
    assert second["metadata"]["active_client"]["id"] == crm.c["Costa Verde"]
    bounded(model, start)


# =====================================================================
# 2. Ambigüedad → aclaración por el historial → contacto resuelto
# =====================================================================

def test_carlos_ambiguo_y_aclaracion(client, user_a, crm, model, dbq):
    model.script([("find_entities", {"contact_name": "Carlos"})],
                 [("get_contact", {"contact_id": crm.ct["ruiz"]})],          # intenta usar un candidato
                 "¿Carlos Perez de Tecnologia Rivera SL o Carlos Ruiz de Instituto San Lucas?")
    first = ask(client, user_a, "¿Qué tengo con Carlos?")
    cid = first["conversation_id"]

    ambiguous = tool_results(model.requests[1])[0]["contact"]
    assert ambiguous["status"] == "ambiguous" and ambiguous["id"] is None
    assert {(c["name"], c["client_name"]) for c in ambiguous["candidates"]} == {
        ("Carlos Perez", "Tecnologia Rivera SL"), ("Carlos Ruiz", "Instituto San Lucas")}
    assert last_result(model.requests[2])["error"] == "unknown_id"     # sin id de confianza
    assert first["metadata"] == {"active_client": None, "active_contact": None}

    model.script([("find_entities", {"contact_name": "Carlos", "client_name": "San Lucas"})],
                 lambda r: [("list_activities", {"contact_id": last_result(r)["contact"]["id"]})],
                 "Con Carlos Ruiz tienes una actividad la semana pasada.")
    second = ask(client, user_a, "El de San Lucas.", cid)

    turn2 = model.requests[3]["messages"]
    assert [m["content"] for m in turn2 if m["role"] in ("user", "assistant")][-3:] == [
        "¿Qué tengo con Carlos?", "¿Carlos Perez de Tecnologia Rivera SL o Carlos Ruiz de Instituto San Lucas?",
        "El de San Lucas."]
    assert trace(dbq, cid) == [
        ("find_entities", {"client_name": "San Lucas", "contact_name": "Carlos"}, "ok"),
        ("list_activities", {"contact_id": crm.ct["ruiz"]}, "ok")]
    assert second["metadata"] == {
        "active_client": {"id": crm.c["San Lucas"], "name": "Instituto San Lucas"},
        "active_contact": {"id": crm.ct["ruiz"], "name": "Carlos Ruiz", "client_id": crm.c["San Lucas"]}}


# =====================================================================
# 3. Prioridades con attention → seguimiento sobre un cliente devuelto
# =====================================================================

def test_attention_y_seguimiento(client, user_a, crm, model, dbq):
    model.script([("crm_rankings", {"metric": "attention", "limit": 6})],
                 "Revisa primero Colegio Nuevo Horizonte: nunca lo has contactado y está entre los que más facturan.")
    first = ask(client, user_a, "¿Qué clientes debería revisar?")
    cid = first["conversation_id"]

    ranking = last_result(model.requests[-1])
    order = [(i["client"]["name"], i["signals"]) for i in ranking["items"]]
    assert order == [
        ("Colegio Nuevo Horizonte", ["never_contacted", "no_upcoming", "top_billing", "top_billing_low_attention"]),
        ("Ayuntamiento de Valle Alto", ["never_contacted", "no_upcoming"]),          # B sí lo atiende; A no
        ("Grupo Sierra Norte SL", ["inactive_90d", "no_upcoming"]),
        ("Diputacion Costa Verde", ["no_upcoming"]),
        ("Instituto San Lucas", ["top_billing"]),
        ("Tecnologia Rivera SL", []),
    ]
    assert "no una puntuación" in ranking["rules"]
    assert first["metadata"]["active_client"] is None        # un ranking no fija cliente activo

    model.script([("find_entities", {"client_name": "Nuevo Horizonte"})],
                 lambda r: [("get_client_overview", {"client_id": found_client_id(r)})],
                 "Colegio Nuevo Horizonte factura 37.000 € (total del cliente) y no tienes actividades con él.")
    second = ask(client, user_a, "¿Y qué sabemos de Nuevo Horizonte?", cid)

    overview = last_result(model.requests[-1])
    assert overview["activity"]["total"] == 0 and overview["billing"]["total_billed"] == 37000
    assert second["metadata"]["active_client"]["id"] == crm.c["Nuevo Horizonte"]


# =====================================================================
# 4. Fechas relativas: la semana pasada
# =====================================================================

def test_que_hice_la_semana_pasada(client, user_a, crm, model, dbq):
    model.script([("list_activities", {"temporal_scope": "last_week"})],
                 "La semana pasada tuviste 2 actividades.")
    body = ask(client, user_a, "¿Qué hice la semana pasada?")

    calendar = state_of(model.requests[0])["calendario"]
    assert calendar["semana_pasada"] == {"desde": "2026-09-28", "hasta": "2026-10-04"}
    week = last_result(model.requests[-1])
    assert [(a["client"]["name"], a["datetime"]) for a in week["activities"]] == [
        ("Tecnologia Rivera SL", "2026-09-30T09:00:00"), ("Instituto San Lucas", "2026-10-02T16:00:00.000")]
    assert B_MARK not in json.dumps(week)                     # la de B del 01/10 no aparece
    assert trace(dbq, body["conversation_id"]) == [("list_activities", {"temporal_scope": "last_week"}, "ok")]


# =====================================================================
# 5. Mañana + preparar reuniones: varias herramientas y contexto seguro
# =====================================================================

def test_manana_y_que_preparo(client, user_a, crm, model, dbq):
    model.script([("find_entities", {"client_name": "Costa"})], "Costa va bien.")
    cid = ask(client, user_a, "¿Cómo va Costa?")["conversation_id"]

    start = len(model.requests)
    model.script([("list_activities", {"temporal_scope": "tomorrow"})],
                 lambda r: [("prepare_meeting_context", {"client_id": a["client"]["id"]})
                            for a in last_result(r)["activities"]],
                 "Mañana tienes dos reuniones: Tecnologia Rivera SL y Instituto San Lucas.")
    body = ask(client, user_a, "¿Qué tengo mañana y qué preparo?", cid)

    assert trace(dbq, cid) == [
        ("list_activities", {"temporal_scope": "tomorrow"}, "ok"),
        ("prepare_meeting_context", {"client_id": crm.c["Rivera"]}, "ok"),     # ids aprendidos de la lista
        ("prepare_meeting_context", {"client_id": crm.c["San Lucas"]}, "ok")]
    # Dos clientes en el turno: no se deja ninguno como "activo" (tampoco el anterior, Costa)
    assert body["metadata"] == {"active_client": None, "active_contact": None}
    briefings = tool_results(model.requests[-1])[1:]
    assert all("phone" not in json.dumps(b["contacts"]) for b in briefings)
    bounded(model, start)


# =====================================================================
# 6. Búsqueda semántica caída → alternativa determinista
# =====================================================================

def test_busqueda_semantica_no_disponible_usa_la_lista(client, user_a, crm, model, dbq, chat_embeddings):
    chat_embeddings.error = RuntimeError("caída del proveedor sk-test")
    model.script([("search_activities", {"query": "Monitor Mar 24"})],
                 [("list_activities", {"product_name": "Monitor Mar 24"})],
                 "La búsqueda por contenido no estaba disponible; por producto, lo trataste con Diputacion "
                 "Costa Verde el 15 de septiembre.")
    body = ask(client, user_a, "¿Qué clientes han hablado del Monitor Mar 24?")

    statuses = [(name, status) for name, _, status in trace(dbq, body["conversation_id"])]
    assert statuses == [("search_activities", "tool_unavailable"), ("list_activities", "ok")]
    by_product = last_result(model.requests[-1])
    assert by_product["product_filter"]["status"] == "resolved"
    assert [a["client"]["name"] for a in by_product["activities"]] == ["Diputacion Costa Verde"]
    assert B_MARK not in json.dumps(by_product)              # B también lo trató con Costa, pero no cuenta
    assert "sk-test" not in model.sent_text()


# =====================================================================
# 7. Entre comerciales: prioridades aisladas
# =====================================================================

def test_prioridades_aisladas_entre_comerciales(client, user_a, user_b, crm, model):
    script = [[("crm_rankings", {"metric": "attention", "limit": 6}),
               ("list_activities", {"temporal_scope": "past", "limit": 20})], "Prioridades."]
    model.script(*script)
    ask(client, user_a, "¿Dónde debería centrarme?")
    evidence_a = json.dumps(tool_results(model.requests[-1]))
    model.script(*script)
    ask(client, user_b, "¿Dónde debería centrarme?")
    evidence_b = json.dumps(tool_results(model.requests[-1]))

    assert A_MARK in evidence_a and B_MARK not in evidence_a
    assert B_MARK in evidence_b and A_MARK not in evidence_b
    attention_b = {i["client"]["name"]: i["signals"]
                   for i in tool_results(model.requests[-1])[0]["items"]}
    assert "never_contacted" not in attention_b["Ayuntamiento de Valle Alto"]     # B sí lo ha contactado
    assert "never_contacted" in attention_b["Tecnologia Rivera SL"]              # lo de A no cuenta para B
    assert "2026-05-01" not in evidence_b and "2026-10-06" not in evidence_a      # fechas del otro


# =====================================================================
# 8. Resistencia a alucinaciones: desconocido, id inventado, candidato ambiguo
# =====================================================================

def test_sin_datos_inventados(client, user_a, crm, model, dbq):
    model.script([("find_entities", {"client_name": "Construcciones Mediterraneo"}),
                  ("find_entities", {"contact_name": "Carlos"})],
                 [("get_client_overview", {"client_id": crm.c["Rivera"]}),    # id real, pero no conocido
                  ("get_contact", {"contact_id": crm.ct["perez"]}),           # candidato ambiguo
                  ("get_client_overview", {"client_id": 999999})],            # id inventado
                 "No encuentro Construcciones Mediterraneo y hay dos Carlos.")
    body = ask(client, user_a, "¿Cómo va Construcciones Mediterraneo y qué tengo con Carlos?")

    assert [s for _, _, s in trace(dbq, body["conversation_id"])] == [
        "ok", "ok", "unknown_id", "unknown_id", "unknown_id"]
    evidence = json.dumps(tool_results(model.requests[-1]))
    assert A_MARK not in evidence and B_MARK not in evidence    # ningún dato de actividad llegó al modelo
    assert body["metadata"] == {"active_client": None, "active_contact": None}


# =====================================================================
# Prueba real de G.4: el contexto activo NO es un filtro por defecto
# (el modelo real añadía client_id/contact_id del estado a preguntas generales)
# =====================================================================

def _activate(client, user, model, alias):
    model.script([("find_entities", {"client_name": alias})],
                 lambda r: [("get_client_overview", {"client_id": found_client_id(r)})], f"{alias} ok.")
    return ask(client, user, f"¿Cómo va {alias}?")["conversation_id"]


def _product_id(name):
    conn = db.get_connection()
    try:
        return conn.execute("SELECT id FROM products WHERE nombre = ?", (name,)).fetchone()[0]
    finally:
        conn.close()


def _no_entity_filters(dbq, cid):
    return all(not ({"client_id", "contact_id"} & set(args)) for _, args, _ in trace(dbq, cid))


def test_preguntas_generales_con_cliente_activo_no_filtran(client, user_a, crm, model, dbq, factory):
    factory.activity(crm.a, crm.c["Rivera"], datetime_iso="2026-10-06T10:00:00", comentario=f"{A_MARK} ayer R")
    factory.activity(crm.a, crm.c["Costa Verde"], datetime_iso="2026-10-06T17:00:00", comentario=f"{A_MARK} ayer C")
    cid = _activate(client, user_a, model, "Rivera")

    for message, scope, expected in [
        ("¿Qué hice ayer?", "yesterday", [("Tecnologia Rivera SL", "2026-10-06T10:00:00"),
                                          ("Diputacion Costa Verde", "2026-10-06T17:00:00")]),
        ("¿Qué tengo mañana?", "tomorrow", [("Tecnologia Rivera SL", "2026-10-08T09:30:00"),
                                           ("Instituto San Lucas", "2026-10-08T16:00:00")]),
        ("¿Qué hice la semana pasada?", "last_week", [("Tecnologia Rivera SL", "2026-09-30T09:00:00"),
                                                     ("Instituto San Lucas", "2026-10-02T16:00:00.000")]),
    ]:
        model.script([("list_activities", {"temporal_scope": scope})], "Respuesta.")
        body = ask(client, user_a, message, cid)

        state = state_of(model.requests[-2])
        assert state["cliente_activo"]["id"] == crm.c["Rivera"] and "no son un filtro" in state["nota"]
        result = last_result(model.requests[-1])
        assert [(a["client"]["name"], a["datetime"]) for a in result["activities"]] == expected   # todos los clientes
        assert B_MARK not in json.dumps(result)
        assert _no_entity_filters(dbq, cid)
        # Una consulta general no cambia el contexto: los pronombres siguen refiriéndose a Rivera
        assert body["metadata"]["active_client"]["id"] == crm.c["Rivera"]


def test_con_que_clientes_he_hablado_de_un_producto_es_global(client, user_a, crm, model, dbq, factory):
    monitor = _product_id("Monitor Mar 24")
    factory.activity(crm.a, crm.c["San Lucas"], datetime_iso="2026-09-20T10:00:00", comentario=A_MARK,
                     products=[(monitor, "raw")])
    cid = _activate(client, user_a, model, "San Lucas")

    model.script([("list_activities", {"product_name": "Monitor Mar 24"})],
                 "Has tratado Monitor Mar 24 con Diputacion Costa Verde e Instituto San Lucas.")
    body = ask(client, user_a, "¿Con qué clientes he hablado del Monitor Mar 24?", cid)

    product = last_result(model.requests[-1])["product_filter"]
    assert product["status"] == "resolved" and product["product"] == "Monitor Mar 24"
    # Resumen por cliente de TODAS tus actividades con el producto (la de B con Costa no cuenta)
    assert [(c["client"]["name"], c["activity_count"]) for c in product["by_client"]] == [
        ("Diputacion Costa Verde", 1), ("Instituto San Lucas", 1)]
    assert _no_entity_filters(dbq, cid)
    assert body["metadata"]["active_client"]["id"] == crm.c["San Lucas"]


def test_producto_con_tilde_y_cliente_activo_rivera_es_global(client, user_a, crm, model, dbq, factory):
    faro = factory.product("Raton Faro", 25)
    for owner, alias, when in [(crm.a, "Rivera", "2026-05-18T10:00:00"), (crm.a, "Costa Verde", "2026-05-20T10:00:00"),
                               (crm.a, "Costa Verde", "2026-06-02T10:00:00"), (crm.b, "Valle Alto", "2026-06-03T10:00:00")]:
        factory.activity(owner, crm.c[alias], datetime_iso=when, comentario=A_MARK if owner == crm.a else B_MARK,
                         products=[(faro, "raw")])
    cid = _activate(client, user_a, model, "Rivera")

    model.script([("list_activities", {"product_name": "Ratón Faro"})], "Con Costa Verde (2) y Rivera (1).")
    ask(client, user_a, "¿Qué clientes han hablado conmigo sobre el Ratón Faro?", cid)

    product = last_result(model.requests[-1])["product_filter"]
    assert [(c["client"]["name"], c["activity_count"]) for c in product["by_client"]] == [
        ("Diputacion Costa Verde", 2), ("Tecnologia Rivera SL", 1)]          # Valle es de B: no aparece
    assert B_MARK not in json.dumps(last_result(model.requests[-1]))


def test_referencias_contextuales_siguen_usando_el_estado(client, user_a, crm, model, dbq, factory):
    factory.activity(crm.a, crm.c["Rivera"], datetime_iso="2026-10-06T10:00:00", comentario=A_MARK)
    factory.activity(crm.a, crm.c["Costa Verde"], datetime_iso="2026-10-06T17:00:00", comentario=A_MARK)
    model.script([("find_entities", {"contact_name": "Carlos Perez"})],
                 lambda r: [("get_contact", {"contact_id": last_result(r)["contact"]["id"]})], "Carlos Perez.")
    cid = ask(client, user_a, "¿Quién es Carlos Perez?")["conversation_id"]

    # Sin find_entities: los ids del estado activo (Rivera + Carlos Perez) son de confianza
    for message, step, expected in [
        ("¿Qué hice ayer con ellos?", ("list_activities", {"client_id": crm.c["Rivera"], "temporal_scope": "yesterday"}),
         ["Tecnologia Rivera SL"]),
        ("¿Qué tengo mañana con él?", ("list_activities", {"contact_id": crm.ct["perez"], "temporal_scope": "tomorrow"}),
         ["Tecnologia Rivera SL"]),
        ("¿Y mañana?", ("list_activities", {"client_id": crm.c["Rivera"], "temporal_scope": "tomorrow"}),
         ["Tecnologia Rivera SL"]),
    ]:
        model.script([step], "Respuesta.")
        body = ask(client, user_a, message, cid)
        result = last_result(model.requests[-1])
        assert result["ok"] and [a["client"]["name"] for a in result["activities"]] == expected
        assert body["metadata"]["active_contact"]["id"] == crm.ct["perez"]

    model.script([("get_client_products", {"client_id": crm.c["Rivera"]})], "Productos de Rivera.")
    ask(client, user_a, "¿Y sus productos?", cid)
    assert last_result(model.requests[-1])["ok"] is True


def test_entidad_explicita_sustituye_el_contexto(client, user_a, crm, model):
    cid = _activate(client, user_a, model, "San Lucas")

    model.script([("find_entities", {"client_name": "Rivera"})],
                 lambda r: [("prepare_meeting_context", {"client_id": found_client_id(r)})], "Briefing de Rivera.")
    body = ask(client, user_a, "Prepárame para Rivera.", cid)

    assert body["metadata"]["active_client"] == {"id": crm.c["Rivera"], "name": "Tecnologia Rivera SL"}


def test_que_priorizar_manana_agenda_y_despues_atencion(client, user_a, crm, model, dbq):
    cid = _activate(client, user_a, model, "Costa Verde")
    start = len(model.requests)

    model.script([("list_activities", {"temporal_scope": "tomorrow"}), ("crm_rankings", {"metric": "attention"})],
                 "Mañana tienes dos compromisos (Rivera y San Lucas). Además, según las señales del CRM, "
                 "conviene revisar Colegio Nuevo Horizonte.")
    body = ask(client, user_a, "¿Qué debería priorizar mañana y por qué?", cid)

    agenda, attention = tool_results(model.requests[-1])
    assert [a["client"]["name"] for a in agenda["activities"]] == ["Tecnologia Rivera SL", "Instituto San Lucas"]
    assert attention["items"][0]["client"]["name"] == "Colegio Nuevo Horizonte" and "rules" in attention
    assert trace(dbq, cid) == [("list_activities", {"temporal_scope": "tomorrow"}, "ok"),
                               ("crm_rankings", {"metric": "attention"}, "ok")]
    assert body["metadata"]["active_client"]["id"] == crm.c["Costa Verde"]     # sin foco: el contexto sigue
    bounded(model, start)


def test_descripciones_de_las_herramientas_no_empujan_el_contexto():
    from services import chat_tools

    schemas = {t["function"]["name"]: t["function"] for t in chat_tools.TOOL_SCHEMAS}
    for tool in ("list_activities", "search_activities"):
        client_id = schemas[tool]["parameters"]["properties"]["client_id"]["description"]
        assert "Solo si el mensaje actual" in client_id and "null" in client_id
        assert "del cliente activo" not in client_id
    assert "TODAS sus actividades" in schemas["list_activities"]["description"]
    assert "product_name" in schemas["search_activities"]["description"]


# =====================================================================
# Prueba real final de G.4 — matriz de alcance (contexto activo: Costa Verde)
# =====================================================================

COSTA = "Diputacion Costa Verde"


def _with_costa(client, user, model):
    return _activate(client, user, model, "Costa Verde")


def conversation_row(dbq, cid):
    return dbq.one("SELECT active_client_id, active_contact_id FROM chat_conversations WHERE id = ?", (cid,))


def test_scope_a_pronombre_usa_el_contexto(client, user_a, crm, model):
    cid = _with_costa(client, user_a, model)
    model.script([("list_activities", {"client_id": crm.c["Costa Verde"], "temporal_scope": "past", "limit": 1})],
                 "El 15 de septiembre.")
    ask(client, user_a, "¿Y cuándo fue mi última actividad con ellos?", cid)

    result = last_result(model.requests[-1])
    assert result["ok"] and [a["datetime"] for a in result["activities"]] == ["2026-09-15T10:00:00"]


def test_scope_b_h_i_global_explicito_conserva_el_contexto(client, user_a, crm, model, dbq):
    cid = _with_costa(client, user_a, model)

    # B: "en general" → global (si el modelo filtrara por el contexto, el backend lo rechaza)
    model.script([("list_activities", {"client_id": crm.c["Costa Verde"], "temporal_scope": "last_week"})],
                 [("list_activities", {"temporal_scope": "last_week"})], "Dos actividades la semana pasada.")
    body = ask(client, user_a, "¿Qué hice la semana pasada en general?", cid)
    rejected, week = tool_results(model.requests[-1])
    assert rejected["error"] == "scope_global"
    assert [a["client"]["name"] for a in week["activities"]] == ["Tecnologia Rivera SL", "Instituto San Lucas"]
    assert body["metadata"]["active_client"]["name"] == COSTA                 # el contexto sigue

    # H: global de nuevo
    model.script([("list_activities", {"temporal_scope": "tomorrow"})], "Mañana: Rivera y San Lucas.")
    ask(client, user_a, "¿Qué tengo mañana en general?", cid)
    assert len(last_result(model.requests[-1])["activities"]) == 2
    assert conversation_row(dbq, cid)["active_client_id"] == crm.c["Costa Verde"]

    # I: el pronombre sigue refiriéndose a Costa
    model.script([("list_activities", {"client_id": crm.c["Costa Verde"], "temporal_scope": "past", "limit": 1})],
                 "El 15 de septiembre.")
    ask(client, user_a, "¿Cuándo fue mi última actividad con ellos?", cid)
    assert last_result(model.requests[-1])["ok"] is True


@pytest.mark.parametrize("answer, expected_scoped", [("En general.", False), ("Con Costa.", True)])
def test_scope_c_d_e_ambiguo_pide_aclarar_y_continua(client, user_a, crm, model, dbq, answer, expected_scoped):
    cid = _with_costa(client, user_a, model)

    # C: el modelo intenta acotar con el contexto sin que el usuario lo pida → no se consulta nada
    model.script([("list_activities", {"client_id": crm.c["Costa Verde"], "temporal_scope": "last_week"})],
                 f"¿Te refieres a {COSTA} o a todas tus actividades?")
    first = ask(client, user_a, "¿Qué hice la semana pasada?", cid)
    guard = last_result(model.requests[-1])
    assert guard["ok"] is False and guard["error"] == "scope_ambiguous"
    assert A_MARK not in json.dumps(tool_results(model.requests[-1]))      # ningún dato de actividad
    assert first["content"] == f"¿Te refieres a {COSTA} o a todas tus actividades?"
    assert first["metadata"]["active_client"]["name"] == COSTA              # la aclaración no cambia el estado

    # D / E: la respuesta del usuario fija el alcance con el historial normal
    step = (("list_activities", {"client_id": crm.c["Costa Verde"], "temporal_scope": "last_week"}) if expected_scoped
            else ("list_activities", {"temporal_scope": "last_week"}))
    model.script([step], "Respuesta.")
    ask(client, user_a, answer, cid)
    history = [m["content"] for m in model.requests[-2]["messages"] if m["role"] in ("user", "assistant")]
    assert history[-3:] == ["¿Qué hice la semana pasada?", f"¿Te refieres a {COSTA} o a todas tus actividades?", answer]
    result = last_result(model.requests[-1])
    assert result["ok"] is True
    names = [a["client"]["name"] for a in result["activities"]]
    # Costa la semana pasada: solo hay una de B (no cuenta) → vacío; global: Rivera y San Lucas
    assert names == ([] if expected_scoped else ["Tecnologia Rivera SL", "Instituto San Lucas"])
    assert B_MARK not in json.dumps(result)


def test_scope_f_g_olvidar_el_contexto_se_guarda(client, user_a, crm, model, dbq, factory):
    factory.activity(crm.a, crm.c["Rivera"], datetime_iso="2026-10-06T10:00:00", comentario=A_MARK)
    cid = _with_costa(client, user_a, model)

    # F: "Olvida Costa." borra y guarda el contexto
    model.script("Hecho, ya no tengo ningún cliente activo.")
    body = ask(client, user_a, "Olvida Costa.", cid)
    assert body["metadata"] == {"active_client": None, "active_contact": None}
    assert conversation_row(dbq, cid) == {"active_client_id": None, "active_contact_id": None}
    assert '"cliente_activo": null' in model.requests[-1]["messages"][1]["content"]
    stored = json.loads(dbq.all("SELECT metadata FROM chat_messages ORDER BY id")[-1]["metadata"])
    assert stored["context_cleared"] is True

    # G: después, "¿Qué hice ayer?" es global sin aclaración; el id de Costa ya no es de confianza
    model.script([("list_activities", {"client_id": crm.c["Costa Verde"], "temporal_scope": "yesterday"}),
                  ("list_activities", {"temporal_scope": "yesterday"})], "Ayer: una visita a Rivera.")
    ask(client, user_a, "¿Qué hice ayer?", cid)
    stale, yesterday = tool_results(model.requests[-1])
    assert stale["error"] == "unknown_id"
    assert [a["client"]["name"] for a in yesterday["activities"]] == ["Tecnologia Rivera SL"]


def test_scope_olvidar_y_preguntar_en_el_mismo_mensaje(client, user_a, crm, model, dbq):
    cid = _with_costa(client, user_a, model)
    model.script([("list_activities", {"temporal_scope": "yesterday"})], "Ayer no registraste actividades.")

    body = ask(client, user_a, "Olvida Costa. ¿Qué hice ayer?", cid)

    assert body["metadata"]["active_client"] is None
    assert conversation_row(dbq, cid)["active_client_id"] is None


def test_scope_j_olvidar_con_contacto_activo_no_deja_contacto_suelto(client, user_a, crm, model, dbq):
    model.script([("find_entities", {"contact_name": "Carlos Perez"})],
                 lambda r: [("get_contact", {"contact_id": last_result(r)["contact"]["id"]})], "Carlos Perez.")
    cid = ask(client, user_a, "¿Quién es Carlos Perez?")["conversation_id"]
    assert conversation_row(dbq, cid) == {"active_client_id": crm.c["Rivera"], "active_contact_id": crm.ct["perez"]}

    model.script("Hecho.")
    body = ask(client, user_a, "Olvida ese cliente.", cid)

    assert body["metadata"] == {"active_client": None, "active_contact": None}
    assert conversation_row(dbq, cid) == {"active_client_id": None, "active_contact_id": None}


# =====================================================================
# Prueba real final de G.4 — matriz de productos (por cliente, sin fechas inventadas)
# =====================================================================

@pytest.fixture
def faro(crm, factory):
    product = factory.product("Raton Faro", 25)
    monitor = _product_id("Monitor Mar 24")
    rows = [(crm.a, "Instituto San Lucas", "2026-03-09T17:00:00", [product, monitor]),
            (crm.a, "Instituto San Lucas", "2026-03-13T16:00:00.000", [product]),
            (crm.a, "Grupo Sierra Norte SL", "2026-03-13T16:30:00.000", [product]),
            (crm.a, "Colegio Nuevo Horizonte", "2026-03-08T11:00:00.000", [product]),
            (crm.a, "Tecnologia Rivera SL", "2026-05-18T20:00:00", [product]),
            (crm.a, "Diputacion Costa Verde", "2026-05-20T17:00:00", [product]),
            (crm.b, "Instituto San Lucas", "2026-03-13T17:00:00", [product])]          # de B: no cuenta
    by_name = {"Instituto San Lucas": "San Lucas", "Grupo Sierra Norte SL": "Sierra Norte",
               "Colegio Nuevo Horizonte": "Nuevo Horizonte", "Tecnologia Rivera SL": "Rivera",
               "Diputacion Costa Verde": "Costa Verde"}
    for owner, name, when, products in rows:
        factory.activity(owner, crm.c[by_name[name]], datetime_iso=when, comentario=A_MARK if owner == crm.a else B_MARK,
                         products=[(p, "raw") for p in products])
    return product


def _by_client(result):
    return [(c["client"]["name"], c["activity_count"]) for c in result["product_filter"]["by_client"]]


def test_productos_a_f_global_por_cliente_con_contexto_activo(client, user_a, crm, model, dbq, faro):
    cid = _with_costa(client, user_a, model)

    # A: Raton Faro, global aunque Costa esté activo
    model.script([("list_activities", {"product_name": "raton faro"})], "Has tratado Raton Faro con 5 clientes.")
    ask(client, user_a, "¿Con qué clientes he hablado del Ratón Faro?", cid)
    faro_result = last_result(model.requests[-1])
    assert _by_client(faro_result) == [("Instituto San Lucas", 2), ("Colegio Nuevo Horizonte", 1),
                                       ("Diputacion Costa Verde", 1), ("Grupo Sierra Norte SL", 1),
                                       ("Tecnologia Rivera SL", 1)]
    assert B_MARK not in json.dumps(faro_result)                               # D: lo de B no cuenta

    # B: Monitor Mar 24 en varios clientes
    model.script([("list_activities", {"product_name": "Monitor Mar 24"})], "Con Costa Verde y San Lucas.")
    ask(client, user_a, "¿Con qué clientes he hablado del Monitor Mar 24?", cid)
    assert _by_client(last_result(model.requests[-1])) == [("Diputacion Costa Verde", 1), ("Instituto San Lucas", 1)]

    # C: acotado a un cliente nombrado explícitamente
    model.script([("find_entities", {"client_name": "San Lucas"})],
                 lambda r: [("list_activities", {"client_id": found_client_id(r), "product_name": "Monitor Mar 24"})],
                 "Con San Lucas, una vez.")
    ask(client, user_a, "¿He tratado el Monitor Mar 24 con San Lucas?", cid)
    assert _by_client(last_result(model.requests[-1])) == [("Instituto San Lucas", 1)]

    # Con el periodo inventado de la prueba real: vacío, pero sin parecer "nunca"
    model.script([("list_activities", {"product_name": "raton faro", "temporal_scope": "past",
                                       "date_from": "2026-09-01", "date_to": "2026-10-01"})], "No en septiembre.")
    ask(client, user_a, "¿Hablé del Ratón Faro en septiembre?", cid)
    period = last_result(model.requests[-1])["product_filter"]
    assert period["by_client"] == [] and period["total_without_date_filters"] == 6

    # E: producto inexistente → vacío y fundamentado
    model.script([("list_activities", {"product_name": "Proyector Laser"})], "Ese producto no está en el catálogo.")
    ask(client, user_a, "¿Con qué clientes he hablado del Proyector Laser?", cid)
    missing = last_result(model.requests[-1])
    assert missing["found"] is False and missing["product_filter"]["status"] == "unresolved"
    assert _no_entity_filters(dbq, cid) is True


def test_producto_resumen_por_cliente_cuenta_todas_no_solo_la_pagina(client, user_a, crm, model, faro):
    model.script([("list_activities", {"product_name": "raton faro", "limit": 2})], "Seis actividades en 5 clientes.")
    ask(client, user_a, "¿Con qué clientes he hablado del Ratón Faro?")

    result = last_result(model.requests[-1])
    assert result["count"] == 2 and result["has_more"] is True                 # la lista va paginada...
    assert sum(n for _, n in _by_client(result)) == 6                          # ...el resumen no
