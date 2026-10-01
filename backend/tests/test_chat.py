"""
G.3 — POST /chat: conversación persistente y propia, contexto acotado,
estado activo de confianza, aislamiento entre comerciales, errores de
OpenAI y ninguna escritura en los datos del CRM.

El modelo es un ScriptedModel (conftest): decide qué herramientas pide y
qué responde, de forma determinista. Lo que se prueba son las fronteras del
backend (propiedad, validación, inyección del comercial, ids conocidos,
estado, persistencia), no la calidad del modelo.
"""
import json

import httpx
import openai
import pytest

import db
import main
from conftest import CHAT_A_ONLY, CHAT_B_ONLY, CHAT_NOW
from schemas.chat import CHAT_MESSAGE_MAX_LENGTH
from services import chat as chat_service
from services import chat_orchestrator, crm_tools

NOT_FOUND = {"detail": "Conversación no encontrada"}
EMPTY_STATE = {"active_client": None, "active_contact": None}
SECRET_A = "SECRET_A_ONLY_7F3C"
_REQUEST = httpx.Request("POST", "https://api.openai.invalid/v1/chat/completions")

CRM_TABLES = ("client_groups", "clients", "contacts", "products", "product_aliases", "activity_types",
              "salespeople", "activities", "activity_products", "activity_embeddings", "invoices",
              "invoice_lines")


@pytest.fixture(autouse=True)
def fixed_now(monkeypatch):
    monkeypatch.setattr(chat_service, "current_time", lambda: CHAT_NOW)


def post(client, user, message, conversation_id=None, *, expect=200):
    body = {"message": message}
    if conversation_id is not None:
        body["conversation_id"] = conversation_id
    response = client.post("/chat", json=body, headers=user["headers"])
    assert response.status_code == expect, response.text
    return response.json()


def last_tool(request):
    """Resultado de la última herramienta enviada en una petición al modelo."""
    return json.loads([m for m in request["messages"] if m["role"] == "tool"][-1]["content"])


def resolve_then(tool, **find):
    """Pasos: find_entities(**find) y después `tool` con el id que haya resuelto el backend."""
    def next_step(request):
        found = last_tool(request)
        if tool == "get_contact":
            return [(tool, {"contact_id": found["contact"]["id"]})]
        return [(tool, {"client_id": found["client"]["id"]})]

    return [("find_entities", {"client_name": None, "contact_name": None, **find})], next_step


def crm_dump():
    conn = db.get_connection()
    try:
        return {t: [tuple(r) for r in conn.execute(f"SELECT * FROM {t} ORDER BY rowid")] for t in CRM_TABLES}
    finally:
        conn.close()


def conversation_row(dbq, conversation_id):
    return dbq.one("SELECT salesperson_id, active_client_id, active_contact_id FROM chat_conversations WHERE id = ?",
                   (conversation_id,))


def rivera_ref(chat_crm):
    return {"id": chat_crm.rivera, "name": "Rivera Industrial S.L."}


# =====================================================================
# Autenticación
# =====================================================================

def test_sin_token_no_llega_al_modelo(client, model):
    response = client.post("/chat", json={"message": "hola"})
    assert response.status_code in (401, 403)
    assert model.requests == []


def test_token_de_usuario_inexistente_401_sin_llamar_al_modelo(client, model, jwt_factory):
    token = jwt_factory(99999, "fantasma@test.local")
    response = client.post("/chat", json={"message": "hola"}, headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401 and model.requests == []


# =====================================================================
# Contrato y compatibilidad
# =====================================================================

def test_primer_mensaje_crea_conversacion(client, user_a, model, dbq):
    model.script("Hola, ¿en qué te ayudo?")

    body = post(client, user_a, "hola")

    assert body == {"type": "answer", "content": "Hola, ¿en qué te ayudo?", "metadata": EMPTY_STATE,
                    "conversation_id": body["conversation_id"]}
    assert conversation_row(dbq, body["conversation_id"]) == {
        "salesperson_id": user_a["id"], "active_client_id": None, "active_contact_id": None}
    messages = dbq.all("SELECT role, content FROM chat_messages ORDER BY id")
    assert messages == [{"role": "user", "content": "hola"},
                        {"role": "assistant", "content": "Hola, ¿en qué te ayudo?"}]


def test_continuar_conversacion_envia_el_historial(client, user_a, model, dbq):
    model.script("Primera respuesta", "Segunda respuesta")
    first = post(client, user_a, "primera pregunta")

    second = post(client, user_a, "segunda pregunta", first["conversation_id"])

    assert second["conversation_id"] == first["conversation_id"]
    history = [(m["role"], m["content"]) for m in model.requests[1]["messages"][2:]]
    assert history == [("user", "primera pregunta"), ("assistant", "Primera respuesta"),
                       ("user", "segunda pregunta")]
    assert dbq.one("SELECT COUNT(*) AS n FROM chat_messages")["n"] == 4


def test_sin_conversation_id_cada_mensaje_es_una_conversacion_nueva(client, user_a, model):
    model.script("uno", "dos")
    first, second = post(client, user_a, "uno"), post(client, user_a, "dos")

    assert first["conversation_id"] != second["conversation_id"]
    assert [m["role"] for m in model.requests[1]["messages"]] == ["system", "system", "user"]


def test_el_historial_esta_acotado(client, user_a, model):
    conversation_id = None
    for i in range(12):
        model.script(f"respuesta {i}")
        conversation_id = post(client, user_a, f"pregunta {i}", conversation_id)["conversation_id"]

    sent = model.requests[-1]["messages"]
    assert len(sent) == 2 + 8 + 1  # sistema + estado + 8 mensajes previos + pregunta actual
    assert "pregunta 0" not in model.sent_text([model.requests[-1]])


@pytest.mark.parametrize("message", ["", "   "])
def test_mensaje_vacio_respuesta_controlada_sin_bd_ni_modelo(client, user_a, user_b, model, dbq, message):
    model.script("x")
    foreign = post(client, user_b, "de B")["conversation_id"]

    body = post(client, user_a, message, foreign)

    assert body == {"type": "error", "content": chat_service.EMPTY_MESSAGE, "metadata": None,
                    "conversation_id": None}
    assert len(model.requests) == 1 and dbq.one("SELECT COUNT(*) AS n FROM chat_messages")["n"] == 2


def test_mensaje_con_la_longitud_maxima_se_acepta(client, user_a, model):
    assert post(client, user_a, "a" * CHAT_MESSAGE_MAX_LENGTH)["type"] == "answer"


@pytest.mark.parametrize("body", [
    {"message": "a" * (CHAT_MESSAGE_MAX_LENGTH + 1)},
    {},
    {"message": None},
    {"message": "hola", "conversation_id": 0},
    {"message": "hola", "conversation_id": -3},
    {"message": "hola", "conversation_id": "1"},
    {"message": "hola", "conversation_id": 1.5},
    {"message": "hola", "conversation_id": True},
    {"message": "hola", "conversation_id": 2**63},          # fuera del INTEGER de SQLite: 422, no 500
    {"message": "hola", "conversation_id": 2**70},
    {"message": "hola", "conversation_id": "9223372036854775808"},
], ids=["demasiado_largo", "sin_message", "message_null", "id_0", "id_negativo", "id_texto", "id_decimal",
        "id_bool", "id_2e63", "id_2e70", "id_grande_texto"])
def test_peticion_invalida_422_sin_llamar_al_modelo(client, user_a, model, body):
    response = client.post("/chat", json=body, headers=user_a["headers"])
    assert response.status_code == 422 and model.requests == []


def test_conversation_id_maximo_de_sqlite_es_un_404_controlado(client_no_raise, user_a, model):
    response = client_no_raise.post("/chat", json={"message": "hola", "conversation_id": 2**63 - 1},
                                    headers=user_a["headers"])
    assert (response.status_code, response.json()) == (404, NOT_FOUND) and model.requests == []


def test_conversation_id_null_equivale_a_omitirlo(client, user_a, model):
    response = client.post("/chat", json={"message": "hola", "conversation_id": None}, headers=user_a["headers"])
    assert response.status_code == 200 and response.json()["conversation_id"] > 0


def test_solo_existe_el_endpoint_de_chat():
    paths = {getattr(r, "path", "") for r in main.app.routes}
    assert {p for p in paths if "chat" in p} == {"/chat"}
    assert "/prepare-meeting" not in paths  # legado sustituido por el chat + prepare_meeting_context


def test_prepare_meeting_ya_no_existe(client, user_a, model):
    response = client.post("/prepare-meeting", json={"client_id": 1}, headers=user_a["headers"])
    assert response.status_code == 404 and model.requests == []


# =====================================================================
# Propiedad de la conversación
# =====================================================================

def test_b_no_puede_usar_la_conversacion_de_a(client, user_a, user_b, model, dbq):
    model.script(f"respuesta para A {SECRET_A}")
    conversation_id = post(client, user_a, f"pregunta de A {SECRET_A}")["conversation_id"]
    requests_before = len(model.requests)

    response = client.post("/chat", json={"message": "hola", "conversation_id": conversation_id},
                           headers=user_b["headers"])

    assert response.status_code == 404 and response.json() == NOT_FOUND
    assert len(model.requests) == requests_before  # no se llama al modelo
    assert dbq.one("SELECT COUNT(*) AS n FROM chat_messages")["n"] == 2
    assert SECRET_A not in response.text


def test_misma_respuesta_para_inexistente_y_ajena(client, user_a, user_b, model):
    model.script("x")
    foreign = post(client, user_b, "de B")["conversation_id"]

    missing = client.post("/chat", json={"message": "hola", "conversation_id": foreign + 100},
                          headers=user_a["headers"])
    other = client.post("/chat", json={"message": "hola", "conversation_id": foreign}, headers=user_a["headers"])

    assert (missing.status_code, missing.json()) == (other.status_code, other.json()) == (404, NOT_FOUND)


def test_historial_de_a_nunca_llega_al_modelo_de_b(client, user_a, user_b, model):
    model.script("ok A", "ok B")
    post(client, user_a, f"secreto {SECRET_A}")
    post(client, user_b, "hola")

    assert SECRET_A not in model.sent_text([model.requests[1]])


# =====================================================================
# Estado activo y seguimiento ("ellos", "ese cliente")
# =====================================================================

def test_cliente_activo_se_guarda_y_se_devuelve(client, user_a, chat_crm, model, dbq):
    model.script(*resolve_then("get_client_overview", client_name="Rivera"), "Rivera va bien.")

    body = post(client, user_a, "Cuéntame cómo va Rivera")

    assert body["type"] == "answer" and body["content"] == "Rivera va bien."
    assert body["metadata"] == {"active_client": rivera_ref(chat_crm), "active_contact": None}
    assert conversation_row(dbq, body["conversation_id"])["active_client_id"] == chat_crm.rivera


def test_contacto_activo_implica_su_cliente(client, user_a, chat_crm, model):
    model.script(*resolve_then("get_contact", contact_name="Pablo Gil"), "Pablo Gil es de Nebula.")

    body = post(client, user_a, "¿Qué sabes de Pablo Gil?")

    assert body["metadata"] == {
        "active_client": {"id": chat_crm.nebula, "name": "Nebula Logística S.L."},
        "active_contact": {"id": chat_crm.pablo, "name": "Pablo Gil", "client_id": chat_crm.nebula},
    }


def test_seguimiento_con_pronombre_usa_el_cliente_activo(client, user_a, chat_crm, model):
    model.script(*resolve_then("get_client_overview", client_name="Rivera"), "Rivera va bien.")
    conversation_id = post(client, user_a, "Cuéntame cómo va Rivera")["conversation_id"]

    # Sin find_entities: el id de Rivera ya es de confianza (estado activo)
    model.script([("list_activities", {"client_id": chat_crm.rivera, "temporal_scope": "past", "limit": 1})],
                 "Tu última actividad con Rivera fue el 1 de octubre.")
    body = post(client, user_a, "¿Y cuándo fue mi última actividad con ellos?", conversation_id)

    request = model.requests[-2]
    assert '"cliente_activo": {"id": %d' % chat_crm.rivera in request["messages"][1]["content"]
    result = last_tool(model.requests[-1])
    assert result["ok"] and [a["datetime"] for a in result["activities"]] == ["2026-10-01T10:00:00"]
    assert body["metadata"]["active_client"] == rivera_ref(chat_crm)


def test_cambio_explicito_de_cliente(client, user_a, chat_crm, model):
    model.script(*resolve_then("get_contact", contact_name="Marta López"), "Marta es de Rivera.")
    conversation_id = post(client, user_a, "¿Qué hay de Marta López?")["conversation_id"]

    model.script(*resolve_then("get_client_overview", client_name="Nebula"), "Nebula va regular.")
    body = post(client, user_a, "¿Y Nebula?", conversation_id)

    assert body["metadata"] == {"active_client": {"id": chat_crm.nebula, "name": "Nebula Logística S.L."},
                                "active_contact": None}  # Marta no es de Nebula


def test_comparacion_de_dos_clientes_deja_sin_cliente_activo(client, user_a, chat_crm, model):
    model.script(*resolve_then("get_client_overview", client_name="Rivera"), "Rivera ok.")
    conversation_id = post(client, user_a, "¿Cómo va Rivera?")["conversation_id"]

    model.script([("find_entities", {"client_name": "Rivera"}), ("find_entities", {"client_name": "Nebula"})],
                 "Comparación hecha.")
    body = post(client, user_a, "Compara Rivera y Nebula", conversation_id)

    assert body["metadata"] == EMPTY_STATE


def test_entidad_ambigua_no_cambia_el_contexto(client, user_a, chat_crm, model):
    model.script(*resolve_then("get_client_overview", client_name="Rivera"), "Rivera ok.")
    conversation_id = post(client, user_a, "¿Cómo va Rivera?")["conversation_id"]

    # El modelo intenta usar un candidato ambiguo por su id: no es de confianza
    model.script([("find_entities", {"contact_name": "Marta"})],
                 [("get_contact", {"contact_id": chat_crm.marta_ruiz})],
                 "Hay dos Martas: Marta López y Marta Ruiz. ¿Cuál?")
    body = post(client, user_a, "¿Y Marta?", conversation_id)

    ambiguous = last_tool(model.requests[-2])
    assert ambiguous["contact"]["status"] == "ambiguous" and ambiguous["contact"]["id"] is None
    assert last_tool(model.requests[-1])["error"] == "unknown_id"
    assert body["metadata"] == {"active_client": rivera_ref(chat_crm), "active_contact": None}


def test_entidad_desconocida_no_cambia_el_contexto(client, user_a, chat_crm, model):
    model.script([("find_entities", {"client_name": "Empresa Fantasma"})],
                 "No encuentro ese cliente en el CRM.")

    body = post(client, user_a, "¿Cómo va Empresa Fantasma?")

    result = last_tool(model.requests[-1])
    assert result["found"] is False and result["client"]["status"] == "unresolved"
    assert body["metadata"] == EMPTY_STATE and body["content"] == "No encuentro ese cliente en el CRM."


def test_sin_resultados_llega_found_false_al_modelo(client, user_a, chat_crm, model):
    model.script([("list_activities", {"temporal_scope": "today"})], "Hoy no tienes actividades.")

    body = post(client, user_a, "¿Qué tengo hoy?")

    assert last_tool(model.requests[-1]) == {"ok": True, "found": False, "count": 0, "has_more": False,
                                            "activities": []}
    assert body["content"] == "Hoy no tienes actividades."


def test_entidad_activa_borrada_se_limpia(client, user_a, chat_crm, model, dbq):
    model.script(*resolve_then("get_client_overview", client_name="Sierra Norte"), "Sierra ok.")
    conversation_id = post(client, user_a, "¿Cómo va Sierra Norte?")["conversation_id"]
    assert conversation_row(dbq, conversation_id)["active_client_id"] == chat_crm.sierra

    with db.connection() as conn:
        conn.execute("DELETE FROM clients WHERE id = ?", (chat_crm.sierra,))

    model.script([("get_client_products", {"client_id": chat_crm.sierra})], "¿De qué cliente hablas?")
    body = post(client, user_a, "¿Y qué productos hemos tratado?", conversation_id)

    assert '"cliente_activo": null' in model.requests[-2]["messages"][1]["content"]
    assert last_tool(model.requests[-1])["error"] == "unknown_id"
    assert body["metadata"] == EMPTY_STATE


def test_pronombre_sin_contexto_el_id_inventado_se_rechaza(client, user_a, chat_crm, model):
    model.script([("get_client_products", {"client_id": chat_crm.rivera})], "¿A qué cliente te refieres?")

    body = post(client, user_a, "¿Qué productos hemos tratado con ellos?")

    assert last_tool(model.requests[-1])["error"] == "unknown_id"
    assert body["metadata"] == EMPTY_STATE


# =====================================================================
# B17 (antes xfail): "dame un resumen" → "Nebula" → seguimiento
# =====================================================================

def test_b17_resumen_pendiente_se_resuelve_al_dar_el_cliente(client, user_a, chat_crm, model, dbq):
    # Turno 1: sin cliente, el asistente pregunta (no hay intención pendiente en ningún sitio)
    model.script("¿De qué cliente quieres el resumen?")
    first = post(client, user_a, "Dame un resumen")
    conversation_id = first["conversation_id"]
    assert first["metadata"] == EMPTY_STATE

    # Turno 2: "Nebula" se entiende gracias al historial y se resuelve con las herramientas
    model.script(*resolve_then("get_client_overview", client_name="Nebula"),
                 lambda request: "Resumen de Nebula: " + last_tool(request)["client"]["name"])
    second = post(client, user_a, "Nebula", conversation_id)

    turn2 = model.requests[1]["messages"]
    assert [(m["role"], m["content"]) for m in turn2[2:]] == [
        ("user", "Dame un resumen"), ("assistant", "¿De qué cliente quieres el resumen?"), ("user", "Nebula")]
    overview = last_tool(model.requests[-1])
    assert overview["client"]["id"] == chat_crm.nebula
    assert CHAT_A_ONLY in json.dumps(overview) and CHAT_B_ONLY not in json.dumps(overview)  # comercial inyectado
    assert second == {"type": "answer", "content": "Resumen de Nebula: Nebula Logística S.L.",
                      "metadata": {"active_client": {"id": chat_crm.nebula, "name": "Nebula Logística S.L."},
                                   "active_contact": None},
                      "conversation_id": conversation_id}
    assert conversation_row(dbq, conversation_id)["active_client_id"] == chat_crm.nebula

    # Turno 3: seguimiento sin nombrar al cliente; el id activo es de confianza sin volver a resolver
    model.script([("get_client_products", {"client_id": chat_crm.nebula})], "Con Nebula no hay productos tratados.")
    third = post(client, user_a, "¿Y qué productos hemos tratado?", conversation_id)

    turn3 = model.requests[-2]
    assert '"cliente_activo": {"id": %d, "name": "Nebula Logística S.L."}' % chat_crm.nebula in \
        turn3["messages"][1]["content"]
    products = last_tool(model.requests[-1])
    assert products["ok"] and products["client"]["id"] == chat_crm.nebula
    assert third["metadata"]["active_client"]["id"] == chat_crm.nebula
    assert [t["name"] for t in json.loads(dbq.all(
        "SELECT metadata FROM chat_messages WHERE role = 'assistant' ORDER BY id")[-1]["metadata"])["tools"]] == [
        "get_client_products"]


# =====================================================================
# Errores de OpenAI y de las herramientas
# =====================================================================

@pytest.mark.parametrize("error", [
    openai.AuthenticationError("Incorrect API key provided: sk-test-not-a-real-key",
                               response=httpx.Response(401, request=_REQUEST), body=None),
    openai.APITimeoutError(request=_REQUEST),
    RuntimeError("Incorrect API key provided: sk-test-not-a-real-key"),
], ids=["401", "timeout", "inesperado"])
def test_fallo_de_openai_respuesta_controlada_y_turno_de_error(client, user_a, chat_crm, model, dbq, caplog, error):
    model.script(*resolve_then("get_client_overview", client_name="Rivera"), "Rivera ok.")
    conversation_id = post(client, user_a, "¿Cómo va Rivera?")["conversation_id"]

    model.script([("find_entities", {"client_name": "Nebula"})], error)
    response = client.post("/chat", json={"message": "¿Y Nebula?", "conversation_id": conversation_id},
                           headers=user_a["headers"])

    body = response.json()
    assert response.status_code == 200
    assert body == {"type": "error", "content": chat_service.AI_UNAVAILABLE_MESSAGE,
                    "metadata": {"active_client": rivera_ref(chat_crm), "active_contact": None},
                    "conversation_id": conversation_id}  # el estado no cambia aunque find_entities fuera bien
    for text in (response.text, caplog.text):
        assert "sk-test-not-a-real-key" not in text and "Incorrect API key" not in text
    stored = json.loads(dbq.all("SELECT metadata FROM chat_messages ORDER BY id")[-1]["metadata"])
    assert stored["error"] == chat_orchestrator.AI_UNAVAILABLE

    # El turno fallido no vuelve como contexto: solo su pregunta
    model.script("ok")
    post(client, user_a, "otra cosa", conversation_id)
    assert chat_service.AI_UNAVAILABLE_MESSAGE not in model.sent_text([model.requests[-1]])
    assert "¿Y Nebula?" in model.sent_text([model.requests[-1]])


def test_presupuesto_insuficiente_respuesta_degradada(client, user_a, model, monkeypatch):
    monkeypatch.setattr(chat_orchestrator, "CHAT_TOTAL_BUDGET_S", 1.0)

    body = post(client, user_a, "hola")

    assert body["type"] == "error" and body["content"] == chat_service.BUDGET_EXCEEDED_MESSAGE
    assert model.requests == []


def test_fallo_de_una_herramienta_no_rompe_el_chat(client, user_a, chat_crm, model, monkeypatch, dbq):
    def broken(*args, **kwargs):
        raise RuntimeError("detalle interno /ruta/secreta")

    monkeypatch.setattr(crm_tools, "get_client_overview", broken)
    model.script(*resolve_then("get_client_overview", client_name="Rivera"), "No he podido consultar la ficha.")

    response = client.post("/chat", json={"message": "¿Cómo va Rivera?"}, headers=user_a["headers"])

    assert response.status_code == 200 and "secreta" not in response.text
    assert last_tool(model.requests[-1])["error"] == "tool_failed"
    stored = json.loads(dbq.all("SELECT metadata FROM chat_messages ORDER BY id")[-1]["metadata"])
    assert [(t["name"], t["status"]) for t in stored["tools"]] == [("find_entities", "ok"),
                                                                     ("get_client_overview", "tool_failed")]
    # find_entities sí resolvió Rivera: es el cliente del que se habla
    assert response.json()["metadata"]["active_client"] == rivera_ref(chat_crm)


def test_metadata_guardada_es_compacta(client, user_a, chat_crm, model, dbq):
    model.script(*resolve_then("prepare_meeting_context", client_name="Rivera"), "Briefing listo.")
    post(client, user_a, "Prepárame la reunión con Rivera")

    stored = dbq.all("SELECT metadata FROM chat_messages WHERE role = 'assistant'")[-1]["metadata"]
    assert CHAT_A_ONLY not in stored  # nada de datos del CRM, solo la traza
    assert json.loads(stored) == {"error": None, "tools": [
        {"name": "find_entities", "args": {"client_name": "Rivera"}, "status": "ok", "found": True},
        {"name": "prepare_meeting_context", "args": {"client_id": chat_crm.rivera}, "status": "ok", "found": True},
    ]}


# =====================================================================
# Aislamiento y solo lectura
# =====================================================================

def test_la_evidencia_de_cada_comercial_es_solo_suya(client, user_a, user_b, chat_crm, model, chat_embeddings):
    session = [
        *resolve_then("prepare_meeting_context", client_name="Rivera"),
        [("list_activities", {"client_id": chat_crm.rivera}), ("search_activities", {"query": "visita"}),
         ("crm_rankings", {"metric": "activity_count"})],
        "fin",
    ]
    for user, own, foreign in [(user_a, CHAT_A_ONLY, CHAT_B_ONLY), (user_b, CHAT_B_ONLY, CHAT_A_ONLY)]:
        start = len(model.requests)
        model.script(*session)
        post(client, user, "Prepárame la reunión con Rivera")
        sent = model.sent_text(model.requests[start:])
        assert own in sent and foreign not in sent


def test_el_modelo_no_puede_elegir_el_comercial(client, user_b, chat_crm, model):
    model.script([("list_activities", {"salesperson_id": chat_crm.a}), ("list_activities", {})], "fin")

    post(client, user_b, "dame las actividades del comercial A")

    results = model.last_tool_results()
    assert results[0]["error"] == "invalid_arguments"
    assert CHAT_A_ONLY not in json.dumps(results[1]) and CHAT_B_ONLY in json.dumps(results[1])


def test_una_sesion_completa_no_escribe_en_el_crm(client, user_a, chat_crm, model, chat_embeddings, monkeypatch):
    before = crm_dump()
    model.script(*resolve_then("prepare_meeting_context", client_name="Rivera"),
                 [("list_activities", {"client_id": chat_crm.rivera}), ("search_activities", {"query": "monitor"}),
                  ("get_client_products", {"client_id": chat_crm.rivera})], "uno")
    conversation_id = post(client, user_a, "Prepárame la reunión con Rivera")["conversation_id"]
    model.script(*resolve_then("get_contact", contact_name="Pablo Gil"),
                 [("crm_rankings", {"metric": "inactivity"}), ("search_product_catalog", {"query": "silla"})], "dos")
    post(client, user_a, "¿Y Pablo Gil?", conversation_id)
    model.script(RuntimeError("caída"))
    post(client, user_a, "¿y?", conversation_id)

    assert crm_dump() == before


@pytest.fixture
def tracked_connections(monkeypatch):
    """Registra TODAS las conexiones abiertas (db y los módulos que importan get_connection)."""
    import sys

    real = db.get_connection
    opened = []

    class Tracked:
        def __init__(self, conn):
            self.conn, self.closed = conn, False

        def close(self):
            self.closed = True
            self.conn.close()

        def __getattr__(self, name):
            return getattr(self.conn, name)

    def tracked():
        opened.append(Tracked(real()))
        return opened[-1]

    for module in list(sys.modules.values()):
        if getattr(module, "get_connection", None) is real:
            monkeypatch.setattr(module, "get_connection", tracked)
    return opened


@pytest.mark.parametrize("scenario", ["ok", "openai_falla", "herramienta_falla", "conversacion_ajena"])
def test_todas_las_conexiones_se_cierran(client, user_a, user_b, chat_crm, model, monkeypatch, scenario,
                                         tracked_connections):
    model.script("x")
    foreign = post(client, user_b, "de B")["conversation_id"]
    tracked_connections.clear()
    if scenario == "herramienta_falla":
        monkeypatch.setattr(crm_tools, "list_activities", lambda *a, **k: 1 / 0)
    model.script(*resolve_then("get_client_overview", client_name="Rivera"),
                 [("list_activities", {"temporal_scope": "past"})],
                 RuntimeError("caída") if scenario == "openai_falla" else "fin")

    response = client.post("/chat", json={"message": "¿Cómo va Rivera?",
                                          **({"conversation_id": foreign} if scenario == "conversacion_ajena" else {})},
                           headers=user_a["headers"])

    assert response.status_code == (404 if scenario == "conversacion_ajena" else 200)
    # Lectura de la conversación, entidades, herramientas y guardado del turno: todas cerradas
    assert len(tracked_connections) >= (1 if scenario == "conversacion_ajena" else 4)
    assert all(c.closed for c in tracked_connections)


def test_ninguna_conexion_abierta_mientras_se_espera_al_modelo(client, user_a, chat_crm, model,
                                                               tracked_connections):
    open_during_model = []

    def check(step):
        def wrapped(request):
            open_during_model.append(sum(not c.closed for c in tracked_connections))
            return step(request) if callable(step) else step
        return wrapped

    find, overview = resolve_then("get_client_overview", client_name="Rivera")
    model.script(check(find), check(overview), check("fin"))
    conversation_id = post(client, user_a, "¿Cómo va Rivera?")["conversation_id"]
    model.script(check("seguimiento"))
    post(client, user_a, "¿y?", conversation_id)

    assert open_during_model == [0, 0, 0, 0]


# =====================================================================
# M3 / M4 a través de /chat
# =====================================================================

def test_actividad_incoherente_no_cambia_el_cliente_activo(client, user_a, chat_crm, model, factory):
    factory.activity(chat_crm.a, chat_crm.rivera, contact_id=chat_crm.pablo, datetime_iso="2026-10-05T10:00:00")
    model.script([("list_activities", {"temporal_scope": "past"})],
                 [("list_activities", {"contact_id": chat_crm.pablo})], "Tienes una actividad con Pablo.")

    body = post(client, user_a, "¿Qué hice con Pablo?")

    assert last_tool(model.requests[-1])["count"] == 2  # la incoherente (Rivera) y la normal (Nebula)
    assert body["metadata"] == EMPTY_STATE  # nada deducido del cliente "vecino" en una actividad


def test_conflicto_no_permite_usar_sus_ids(client, user_a, chat_crm, model):
    model.script([("find_entities", {"client_name": "Rivera", "contact_name": "Pablo Gil"})],
                 [("get_contact", {"contact_id": chat_crm.pablo}),
                  ("get_client_overview", {"client_id": chat_crm.rivera})],
                 "Pablo Gil no es contacto de Rivera.")

    body = post(client, user_a, "¿Qué tal Pablo Gil de Rivera?")

    assert [r.get("error") for r in model.last_tool_results()[-2:]] == ["unknown_id", "unknown_id"]
    assert body["metadata"] == EMPTY_STATE


# =====================================================================
# Prueba real (G.3): un nombre o alias explícito se resuelve en el primer
# turno con find_entities, sin exigir un cliente activo ni el nombre completo
# =====================================================================

@pytest.fixture
def dev_like_crm(factory, user_a):
    """Clientes y contactos con la forma de la BD de desarrollo (alias distinto de la razón social)."""
    ids = {alias: factory.client(name, alias=alias) for name, alias in [
        ("Tecnologia Rivera SL", "Rivera"), ("Grupo Sierra Norte SL", "Sierra Norte"),
        ("Instituto San Lucas", "San Lucas"), ("Colegio Nuevo Horizonte", "Nuevo Horizonte")]}
    contacts = {name: factory.contact(ids[client], name) for client, name in [
        ("Rivera", "Marta Lopez"), ("Rivera", "Carlos Perez"), ("San Lucas", "Carlos Ruiz"),
        ("Nuevo Horizonte", "Sonia Vega")]}
    factory.activity(user_a["id"], ids["Rivera"], datetime_iso="2026-10-01T10:00:00",
                     comentario=f"{CHAT_A_ONLY} visita a Rivera")
    return ids, contacts


def test_la_guia_del_modelo_pide_buscar_nombres_explicitos_sin_cliente_activo():
    # Contrato de las instrucciones (la prueba real mostró que el modelo exigía un cliente activo)
    prompt = chat_orchestrator.SYSTEM_PROMPT
    assert "haya o no cliente activo" in prompt and "No pidas el nombre completo" in prompt
    assert '"ellos"' in prompt and "si no hay ninguno, pregunta" in prompt   # pronombres: igual que antes
    find = next(t["function"] for t in chat_orchestrator.chat_tools.TOOL_SCHEMAS
                if t["function"]["name"] == "find_entities")
    assert "alias" in find["description"] and "no hace falta el nombre completo" in find["description"]
    assert "alias" in find["parameters"]["properties"]["client_name"]["description"]


def test_cuentame_como_va_rivera_en_una_conversacion_nueva(client, user_a, dev_like_crm, model, dbq):
    ids, _ = dev_like_crm
    model.script(*resolve_then("get_client_overview", client_name="Rivera"),
                 lambda request: f"{last_tool(request)['client']['name']} va bien.")

    body = post(client, user_a, "Cuéntame cómo va Rivera")

    assert '"cliente_activo": null' in model.requests[0]["messages"][1]["content"]   # sin estado previo
    found = model.tool_results(1)["call_1_0"]
    assert (found["client"]["id"], found["client"]["status"]) == (ids["Rivera"], "exact")
    overview = last_tool(model.requests[-1])
    assert overview["client"]["name"] == "Tecnologia Rivera SL" and CHAT_A_ONLY in json.dumps(overview)
    assert body["content"] == "Tecnologia Rivera SL va bien."
    assert body["metadata"] == {"active_client": {"id": ids["Rivera"], "name": "Tecnologia Rivera SL"},
                                "active_contact": None}
    assert conversation_row(dbq, body["conversation_id"])["active_client_id"] == ids["Rivera"]


@pytest.mark.parametrize("message, find, then, active_client, active_contact", [
    ("¿Qué tengo con Sierra Norte?", {"client_name": "Sierra Norte"}, "list_activities", "Sierra Norte", None),
    ("¿Cómo va San Lucas?", {"client_name": "San Lucas"}, "get_client_overview", "San Lucas", None),
    ("¿Qué sabemos de Marta?", {"contact_name": "Marta"}, "get_contact", "Rivera", "Marta Lopez"),
    ("¿Tengo algo con Sonia Vega?", {"contact_name": "Sonia Vega"}, "get_contact", "Nuevo Horizonte", "Sonia Vega"),
])
def test_alias_o_nombre_explicito_sin_estado_previo(client, user_a, dev_like_crm, model,
                                                   message, find, then, active_client, active_contact):
    ids, contacts = dev_like_crm
    model.script(*resolve_then(then, **find), "Respuesta con los datos.")

    body = post(client, user_a, message)

    found = model.tool_results(1)["call_1_0"]
    assert found["client"]["id"] == ids[active_client]                     # resuelto por la herramienta
    assert last_tool(model.requests[-1])["ok"] is True
    assert body["metadata"]["active_client"]["id"] == ids[active_client]
    expected_contact = contacts[active_contact] if active_contact else None
    assert (body["metadata"]["active_contact"] or {}).get("id") == expected_contact


def test_nombre_realmente_ambiguo_sin_estado_no_se_adivina(client, user_a, dev_like_crm, model):
    _, contacts = dev_like_crm
    model.script([("find_entities", {"contact_name": "Carlos"})],
                 [("get_contact", {"contact_id": contacts["Carlos Perez"]})],
                 "Hay dos Carlos: Carlos Perez y Carlos Ruiz. ¿Cuál?")

    body = post(client, user_a, "¿Qué tengo con Carlos?")

    ambiguous = model.tool_results(1)["call_1_0"]["contact"]
    assert ambiguous["status"] == "ambiguous" and ambiguous["id"] is None
    assert {c["name"] for c in ambiguous["candidates"]} == {"Carlos Perez", "Carlos Ruiz"}
    assert last_tool(model.requests[-1])["error"] == "unknown_id"         # un candidato no se usa sin resolver
    assert body["metadata"] == EMPTY_STATE


def test_contacto_dentro_del_cliente_activo_se_resuelve_sin_ambiguedad(client, user_a, dev_like_crm, model):
    ids, contacts = dev_like_crm
    model.script(*resolve_then("get_client_overview", client_name="Rivera"), "Rivera ok.")
    conversation_id = post(client, user_a, "Cuéntame cómo va Rivera")["conversation_id"]

    # Con Rivera activo, el modelo busca a Carlos dentro de ese cliente (regla 3a)
    model.script(*resolve_then("get_contact", client_name="Tecnologia Rivera SL", contact_name="Carlos"),
                 "Carlos Perez, de Tecnologia Rivera SL.")
    body = post(client, user_a, "¿Qué tengo con Carlos?", conversation_id)

    assert body["metadata"]["active_contact"] == {"id": contacts["Carlos Perez"], "name": "Carlos Perez",
                                                  "client_id": ids["Rivera"]}


def test_empresa_desconocida_sin_estado_no_inventa_datos(client, user_a, dev_like_crm, model):
    model.script([("find_entities", {"client_name": "Construcciones Mediterráneo"})],
                 [("get_client_overview", {"client_id": 1})],
                 "No encuentro esa empresa en el CRM.")

    body = post(client, user_a, "¿Cómo va la empresa Construcciones Mediterráneo?")

    found = model.tool_results(1)["call_1_0"]
    assert found["found"] is False and found["client"]["status"] == "unresolved"
    assert last_tool(model.requests[-1])["error"] == "unknown_id"          # un id inventado no sirve
    assert body["metadata"] == EMPTY_STATE
