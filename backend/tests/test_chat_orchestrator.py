"""
G.3 — Orquestador del chat (services.chat_orchestrator) con un modelo
programado (ScriptedModel): bucle acotado, límites, llamadas repetidas,
presupuesto total, reintentos y respuestas mal formadas. Nunca OpenAI real.
"""
import json
from datetime import datetime
from types import SimpleNamespace

import httpx
import openai
import pytest

from conftest import CHAT_NOW
from services import chat_orchestrator as orch
from services import crm_tools
from services.chat_store import ChatState

_REQUEST = httpx.Request("POST", "https://api.openai.invalid/v1/chat/completions")


class FakeClock:
    def __init__(self):
        self.t = 0.0
        self.sleeps = []

    def __call__(self):
        return self.t

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.t += seconds


@pytest.fixture
def clock():
    return FakeClock()


def run(user, clock, message="pregunta", *, history=(), state=ChatState()):
    return orch.run(message, list(history), state, user, now=CHAT_NOW, clock=clock, sleep=clock.sleep)


def rate_limited(retry_after):
    response = httpx.Response(429, headers={"retry-after": str(retry_after)}, request=_REQUEST)
    return openai.RateLimitError("rate limited", response=response, body=None)


def server_error():
    return openai.InternalServerError("boom", response=httpx.Response(503, request=_REQUEST), body=None)


def rivera_state(chat_crm):
    return ChatState(client={"id": chat_crm.rivera, "name": "Rivera Industrial S.L."})


# =====================================================================
# Flujo normal
# =====================================================================

def test_respuesta_directa_sin_herramientas(chat_crm, model, clock):
    model.script("Hola, ¿en qué te ayudo?")

    result = run(chat_crm.a, clock, "hola")

    assert (result.answer, result.error, result.outcomes) == ("Hola, ¿en qué te ayudo?", None, [])
    request = model.requests[0]
    assert request["model"] == orch.CHAT_MODEL and request["tool_choice"] == "auto"
    assert request["tools"] == orch.chat_tools.TOOL_SCHEMAS
    assert [m["role"] for m in request["messages"]] == ["system", "system", "user"]


def test_mensajes_con_estado_de_confianza_e_historial(chat_crm, model, clock):
    history = [{"role": "user", "content": "antes"}, {"role": "assistant", "content": "respuesta previa"}]
    run(chat_crm.a, clock, "ahora", history=history, state=rivera_state(chat_crm))

    messages = model.requests[0]["messages"]
    assert messages[0]["content"] == orch.SYSTEM_PROMPT
    assert '"cliente_activo": {"id": %d, "name": "Rivera Industrial S.L."}' % chat_crm.rivera in messages[1]["content"]
    assert '"dia_semana": "miércoles"' in messages[1]["content"] and "2026-10-07T12:00" in messages[1]["content"]
    assert messages[2:] == [*history, {"role": "user", "content": "ahora"}]


def test_cadena_de_herramientas_hasta_la_respuesta(chat_crm, model, clock):
    model.script(
        [("find_entities", {"client_name": "Rivera", "contact_name": None})],
        lambda request: [("get_client_overview", {"client_id": model.last_tool_results()[0]["client"]["id"]})],
        "Rivera va bien.",
    )

    result = run(chat_crm.a, clock, "¿Cómo va Rivera?")

    assert result.answer == "Rivera va bien."
    assert [(o.name, o.status) for o in result.outcomes] == [("find_entities", "ok"), ("get_client_overview", "ok")]
    final_messages = model.requests[2]["messages"]
    assert [m["role"] for m in final_messages[-4:]] == ["assistant", "tool", "assistant", "tool"]
    assert final_messages[-1]["tool_call_id"] == "call_2_0"


def test_llamadas_en_paralelo_cada_una_con_su_resultado(chat_crm, model, clock):
    model.script([("crm_rankings", {"metric": "billing"}), ("search_product_catalog", {}),
                  ("list_activities", {"temporal_scope": "tomorrow"})], "ok")

    result = run(chat_crm.a, clock)

    assert [o.status for o in result.outcomes] == ["ok", "ok", "ok"]
    assert set(model.tool_results(1)) == {"call_1_0", "call_1_1", "call_1_2"}


# =====================================================================
# Límites
# =====================================================================

def test_limite_de_herramientas_por_ronda(chat_crm, model, clock):
    model.script([("crm_rankings", {"metric": "billing", "limit": n}) for n in range(1, 7)], "fin")

    result = run(chat_crm.a, clock)

    assert [o.status for o in result.outcomes] == ["ok"] * 4 + ["limit_reached"] * 2
    assert len(model.tool_results(1)) == 6  # todas las tool_calls reciben respuesta


def test_limite_de_herramientas_por_peticion(chat_crm, model, clock, monkeypatch):
    executed = []
    real = crm_tools.crm_rankings
    monkeypatch.setattr(crm_tools, "crm_rankings", lambda *a, **k: executed.append(1) or real(*a, **k))
    rounds = [[("crm_rankings", {"metric": "billing", "limit": r * 4 + n}) for n in range(1, 5)] for r in range(2)]
    model.script(*rounds, [("crm_rankings", {"metric": "inactivity"})], "fin")

    result = run(chat_crm.a, clock)

    assert len(executed) == orch.MAX_TOOL_CALLS_PER_REQUEST
    assert result.outcomes[-1].status == "limit_reached"
    assert model.requests[-1]["tool_choice"] == "none" and result.answer == "fin"


def test_limite_de_llamadas_al_modelo(chat_crm, model, clock):
    model.script(*[[("crm_rankings", {"metric": "billing", "limit": n})] for n in range(1, 10)])

    result = run(chat_crm.a, clock)

    assert len(model.requests) == orch.MAX_MODEL_CALLS
    assert [r["tool_choice"] for r in model.requests] == ["auto", "auto", "auto", "none"]
    # La última (sin herramientas posibles) vuelve a pedir herramientas y sin texto: error controlado
    assert result.answer is None and result.error == orch.AI_UNAVAILABLE


def test_llamada_repetida_no_se_ejecuta_dos_veces(chat_crm, model, clock, monkeypatch):
    executed = []
    real = crm_tools.search_product_catalog
    monkeypatch.setattr(crm_tools, "search_product_catalog", lambda *a, **k: executed.append(1) or real(*a, **k))
    same = [("search_product_catalog", '{"query": null, "limit": 5}')]
    reordered = [("search_product_catalog", '{"limit": 5, "query": null}')]
    model.script(same, reordered, same, "fin")

    result = run(chat_crm.a, clock)

    assert executed == [1]
    assert [o.status for o in result.outcomes] == ["ok", "duplicate_call", "duplicate_call"]
    assert model.requests[-1]["tool_choice"] == "none" and result.answer == "fin"


def test_limite_de_evidencia_fuerza_la_respuesta(chat_crm, model, clock, monkeypatch):
    monkeypatch.setattr(orch, "MAX_EVIDENCE_CHARS", 300)
    model.script([("crm_rankings", {"metric": "billing"}), ("search_product_catalog", {})], "fin")

    result = run(chat_crm.a, clock)

    assert result.outcomes[-1].status == "evidence_limit"
    assert model.requests[-1]["tool_choice"] == "none" and result.answer == "fin"


def test_herramienta_y_argumentos_invalidos_vuelven_al_modelo(chat_crm, model, clock):
    model.script([("drop_database", {}), ("list_activities", "{roto"),
                  ("get_client_overview", {"client_id": 999})], "No puedo hacer eso.")

    result = run(chat_crm.a, clock)

    assert [o.status for o in result.outcomes] == ["unknown_tool", "invalid_arguments", "unknown_id"]
    assert all(not r["ok"] for r in model.tool_results(1).values())
    assert result.answer == "No puedo hacer eso."


def test_fallo_de_herramienta_no_rompe_la_respuesta(chat_crm, model, clock, monkeypatch):
    def broken(*args, **kwargs):
        raise RuntimeError("fallo interno con detalles")

    monkeypatch.setattr(crm_tools, "crm_rankings", broken)
    model.script([("crm_rankings", {"metric": "billing"})], "No he podido consultarlo.")

    result = run(chat_crm.a, clock)

    assert result.outcomes[0].status == "tool_failed" and result.answer == "No he podido consultarlo."
    assert "detalles" not in model.sent_text()


# =====================================================================
# Respuestas mal formadas del modelo
# =====================================================================

@pytest.mark.parametrize("message", [
    SimpleNamespace(content=None, tool_calls=None, refusal=None),
    SimpleNamespace(content="   ", tool_calls=[], refusal=None),
    SimpleNamespace(content=None, tool_calls=None, refusal="No puedo ayudar con eso"),
    SimpleNamespace(content=None, refusal=None, tool_calls=[SimpleNamespace(
        id=None, function=SimpleNamespace(name="crm_rankings", arguments="{}"))]),
    SimpleNamespace(content=None, refusal=None, tool_calls=[SimpleNamespace(id="x", function=None)]),
], ids=["vacio", "solo_espacios", "refusal", "tool_call_sin_id", "tool_call_sin_funcion"])
def test_respuesta_mal_formada_es_error_controlado(chat_crm, model, clock, message):
    model.script(message, "fin")

    result = run(chat_crm.a, clock)

    if message.tool_calls and message.tool_calls[0].id == "x":
        # Sin función: la llamada se responde como herramienta desconocida y el modelo sigue
        assert result.outcomes[0].status == "unknown_tool" and result.answer == "fin"
    else:
        assert result.answer is None and result.error == orch.AI_UNAVAILABLE


# =====================================================================
# Fallos de OpenAI, reintentos y presupuesto
# =====================================================================

def test_fallo_no_reintentable_sin_reintento(chat_crm, model, clock):
    model.script(openai.AuthenticationError("bad key sk-test", response=httpx.Response(401, request=_REQUEST),
                                            body=None))

    result = run(chat_crm.a, clock)

    assert result.error == orch.AI_UNAVAILABLE and len(model.requests) == 1


def test_timeout_no_se_reintenta(chat_crm, model, clock):
    model.script(openai.APITimeoutError(request=_REQUEST))

    assert run(chat_crm.a, clock).error == orch.AI_UNAVAILABLE and len(model.requests) == 1


@pytest.mark.parametrize("error", [openai.APIConnectionError(request=_REQUEST), server_error(), rate_limited(1)],
                         ids=["conexion", "5xx", "429_corto"])
def test_un_unico_reintento_por_peticion(chat_crm, model, clock, error):
    model.script(error, [("crm_rankings", {"metric": "billing"})], error, "fin")

    result = run(chat_crm.a, clock)

    # Primer fallo: se reintenta; segundo fallo (ya en otra llamada): no
    assert len(model.requests) == 3 and result.error == orch.AI_UNAVAILABLE
    assert len(clock.sleeps) == 1


def test_retry_after_largo_no_se_espera(chat_crm, model, clock):
    model.script(rate_limited(30), "fin")

    result = run(chat_crm.a, clock)

    assert result.error == orch.AI_UNAVAILABLE and len(model.requests) == 1 and clock.sleeps == []


def test_sin_presupuesto_para_reintentar(chat_crm, model, clock):
    def slow_failure(request):
        clock.t += orch.CHAT_TOTAL_BUDGET_S - orch.RETRY_MIN_BUDGET_S  # queda justo el mínimo...
        return server_error()                                          # ...menos la espera

    model.script(slow_failure, "fin")

    assert run(chat_crm.a, clock).error == orch.AI_UNAVAILABLE and len(model.requests) == 1


def test_timeout_de_cada_llamada_no_supera_lo_que_queda(chat_crm, model, clock):
    def tools_after(seconds):
        def step(request):
            clock.t += seconds
            return [("crm_rankings", {"metric": "billing", "limit": int(seconds)})]
        return step

    model.script(tools_after(10), tools_after(12), "fin")

    result = run(chat_crm.a, clock)

    # Lo que queda al empezar cada llamada: 30, 20 y 8 s. Conexión + lectura nunca lo supera
    totals = [r["timeout"].connect + r["timeout"].read for r in model.requests]
    assert totals == [pytest.approx(15.0), pytest.approx(15.0), pytest.approx(8.0)]
    assert [(r["timeout"].connect, r["timeout"].read) for r in model.requests[:2]] == [
        (orch.MODEL_CONNECT_TIMEOUT_S, orch.MODEL_READ_TIMEOUT_S)] * 2
    assert all(0 < r["timeout"].connect <= orch.MODEL_CONNECT_TIMEOUT_S for r in model.requests)
    assert result.answer == "fin"


def test_cerca_del_limite_la_conexion_no_se_suma_a_lo_que_queda(chat_crm, model, clock):
    def tools_after(request):
        clock.t += orch.CHAT_TOTAL_BUDGET_S - 3.5  # quedan 3,5 s: aún se puede llamar
        return [("crm_rankings", {"metric": "billing"})]

    model.script(tools_after, "fin")

    run(chat_crm.a, clock)

    last = model.requests[-1]["timeout"]
    # Antes: lectura 3,5 + conexión 3 = 6,5 s. Ahora ambas caben en los 3,5 s
    assert last.connect + last.read == pytest.approx(3.5)
    assert last.connect > 0 and last.read > 0 and last.write == last.read


def test_presupuesto_agotado_no_empieza_otra_llamada(chat_crm, model, clock):
    def slow_tools(request):
        clock.t += orch.CHAT_TOTAL_BUDGET_S - 1
        return [("crm_rankings", {"metric": "billing"})]

    model.script(slow_tools, "nunca se pide")

    result = run(chat_crm.a, clock)

    assert result.error == orch.BUDGET_EXCEEDED and len(model.requests) == 1
    assert [o.status for o in result.outcomes] == ["ok"]


def test_el_cliente_del_chat_no_reintenta_en_el_sdk():
    chat_client = orch.make_chat_client()
    assert chat_client.max_retries == 0
    assert chat_client.timeout.read == orch.get_openai_client().timeout.read  # resto de la config de G.1


# =====================================================================
# G.4 — solo se confía en la evidencia vista, última llamada, calendario y política
# =====================================================================

def test_resultado_descartado_por_el_tope_de_evidencia_no_ensena_ids(chat_crm, model, clock, monkeypatch):
    statuses = []
    real_dispatch = orch.chat_tools.dispatch

    def spy(name, arguments, ctx):
        outcome = real_dispatch(name, arguments, ctx)
        statuses.append((name, outcome.status))
        return outcome

    monkeypatch.setattr(orch.chat_tools, "dispatch", spy)
    monkeypatch.setattr(orch, "MAX_EVIDENCE_CHARS", 100)   # ni siquiera cabe el resultado de find_entities
    model.script([("find_entities", {"client_name": "Rivera"}),
                  ("get_client_overview", {"client_id": chat_crm.rivera})], "fin")

    result = run(chat_crm.a, clock)

    # find_entities se ejecutó bien pero se descartó: su id no pasó a ser de confianza
    assert statuses == [("find_entities", "ok"), ("get_client_overview", "unknown_id")]
    assert result.outcomes[0].status == "evidence_limit"
    assert model.requests[-1]["tool_choice"] == "none"


def test_ultima_llamada_con_texto_y_tool_calls_devuelve_el_texto_sin_ejecutar(chat_crm, model, clock,
                                                                             monkeypatch):
    executed = []
    real = crm_tools.crm_rankings
    monkeypatch.setattr(crm_tools, "crm_rankings", lambda *a, **k: executed.append(a[0]) or real(*a, **k))
    final = SimpleNamespace(content="Respuesta final.", refusal=None, tool_calls=[SimpleNamespace(
        id="call_final", function=SimpleNamespace(name="crm_rankings", arguments='{"metric": "attention"}'))])
    model.script(*[[("crm_rankings", {"metric": "billing", "limit": n})] for n in range(1, 4)], final)

    result = run(chat_crm.a, clock)

    assert result.answer == "Respuesta final."
    assert executed == ["billing"] * 3                       # la de la última llamada no se ejecuta
    assert model.requests[-1]["tool_choice"] == "none"


@pytest.mark.parametrize("now, expected", [
    (datetime(2026, 10, 7, 12, 0), {             # miércoles
        "hoy": "2026-10-07", "ayer": "2026-10-06", "mañana": "2026-10-08",
        "semana_actual": {"desde": "2026-10-05", "hasta": "2026-10-11"},
        "semana_pasada": {"desde": "2026-09-28", "hasta": "2026-10-04"},
        "semana_siguiente": {"desde": "2026-10-12", "hasta": "2026-10-18"}}),
    (datetime(2026, 1, 1, 0, 0), {               # jueves; semana entre dos años
        "hoy": "2026-01-01", "ayer": "2025-12-31", "mañana": "2026-01-02",
        "semana_actual": {"desde": "2025-12-29", "hasta": "2026-01-04"},
        "semana_pasada": {"desde": "2025-12-22", "hasta": "2025-12-28"},
        "semana_siguiente": {"desde": "2026-01-05", "hasta": "2026-01-11"}}),
    (datetime(2026, 10, 11, 23, 59), {           # domingo por la noche: sigue siendo la misma semana
        "hoy": "2026-10-11", "ayer": "2026-10-10", "mañana": "2026-10-12",
        "semana_actual": {"desde": "2026-10-05", "hasta": "2026-10-11"},
        "semana_pasada": {"desde": "2026-09-28", "hasta": "2026-10-04"},
        "semana_siguiente": {"desde": "2026-10-12", "hasta": "2026-10-18"}}),
])
def test_calendario_de_confianza(now, expected):
    assert orch.calendar(now) == expected
    message = orch.state_message(ChatState(client={"id": 3, "name": "X"}), now)
    context = json.loads(message.split("\n", 1)[1])
    assert context["calendario"] == expected
    assert context["cliente_activo"] == {"id": 3, "name": "X"} and context["contacto_activo"] is None


def test_politica_de_respuesta_en_el_prompt():
    prompt = orch.SYSTEM_PROMPT
    for fragment in [
        "primera frase",                                    # responder primero
        "6 viñetas",                                        # evidencia breve
        "15.232 €",                                         # importes
        "Separa los hechos del CRM de tu interpretación",
        "No muestres teléfonos ni emails",
        "Si necesitas algo más",                            # cierre genérico prohibido
        "facturas históricas de todos los comerciales",     # H.5.2: facturas != ventas registradas
        "no las sumes sin decirlo",
        "-> list_sales",
        "overdue = pendiente ya pasada",                    # H.5.2: estados reales
        "-> list_activities con status",
        "nunca las presentes",
        "no una puntuación",                                # attention
        "no inventes otros criterios",
        "He entendido 'Costa'",                             # partial (ejemplo, no frase obligatoria)
        "combinando lo que dijo antes",                     # aclaración
        "evidence_limit",                                   # evidencia parcial
        "puede ser parcial",
        "búsqueda por contenido no estaba disponible",      # fallback de la búsqueda semántica
        "calendario del contexto",
        "haya o no cliente activo",                         # G.3, intacto
        # Prueba real de G.4: el contexto activo no es un filtro por defecto
        "NO es un filtro por defecto",
        "sin client_id ni contact_id",
        # Prueba real final: alcance ambiguo, global explícito, productos sin fechas, dimensión y señales
        "no adivines",
        "scope_ambiguous",
        "el contexto se conserva",
        "el backend ya lo ha quitado",
        "SIN fechas ni temporal_scope",
        "total_without_date_filters",
        "sin atribuir a todos",
        "Responde a la dimensión preguntada",
        "oportunidad valiosa",
        "necesita al menos una herramienta en este turno",
        "list_activities con product_name",
        "mira primero lo que tienes",
        "No conviertas el historial en",
        "deja claro una vez a qué cliente lo has asociado",
        "Estaré encantado",
    ]:
        assert fragment in prompt, fragment
    # H.5.2: la afirmación obsoleta (antes de H.2 no había estados) ya no está
    assert "todavía no guarda si una actividad está hecha" not in prompt
    assert len(prompt) < 6500                               # sigue siendo un prompt acotado (~1,5k tokens)


# =====================================================================
# G.6: una pregunta de periodo sin contexto activo no se responde de memoria
# =====================================================================

def test_periodo_sin_contexto_exige_herramienta_en_la_primera_llamada(chat_crm, model, clock):
    model.script([("crm_rankings", {"metric": "billing", "limit": 1})], "fin")

    result = run(chat_crm.a, clock, "¿Qué tengo mañana?",
                 history=[{"role": "user", "content": "¿Qué tengo hoy?"},
                          {"role": "assistant", "content": "Hoy no tienes actividades."}])

    assert [r["tool_choice"] for r in model.requests] == ["required", "auto"]
    assert result.answer == "fin"


def test_periodo_con_contexto_activo_deja_preguntar_el_alcance(chat_crm, model, clock):
    model.script("¿Te refieres a Rivera o a todas tus actividades?")

    result = run(chat_crm.a, clock, "¿Qué hice la semana pasada?", state=rivera_state(chat_crm))

    assert [r["tool_choice"] for r in model.requests] == ["auto"]
    assert result.answer.startswith("¿Te refieres")


def test_sin_periodo_la_herramienta_no_es_obligatoria(chat_crm, model, clock):
    model.script("Hola")

    run(chat_crm.a, clock, "hola")

    assert model.requests[0]["tool_choice"] == "auto"


def test_el_prompt_prohibe_atribuir_actividades_a_otro_comercial():
    assert "No puedes ver las actividades de otros comerciales" in orch.SYSTEM_PROMPT
    assert "nunca presentes las actividades del usuario como si fueran de otra persona" in orch.SYSTEM_PROMPT
