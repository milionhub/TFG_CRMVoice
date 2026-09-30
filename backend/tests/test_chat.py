"""
D.6 — Chat IA (POST /chat y POST /prepare-meeting): memoria, aislamiento
entre comerciales, contexto CRM, contrato y errores de OpenAI.

Frontera sustituida: el atributo `client` (cliente OpenAI) de ai_router,
openai_service y semantic_search_service. Los prompts los construye el
código real (ai_router.analyze_user_message, openai_service.generate_*,
services.context.build_context, ...); el doble solo registra lo que se
enviaría a OpenAI y devuelve una respuesta controlada.

Memoria real (chat_memory): dos diccionarios globales de proceso, indexados
por user_id (el `sub` del JWT):
  - _last_client_by_user:   {user_id: client_id}
  - _pending_intent_by_user: {user_id: {"intent", "waiting_for": "client"}}
NO se guarda el texto de los mensajes ni historial: ningún prompt incluye
mensajes anteriores. No hay endpoint de reset ni límite/TTL (una entrada
por usuario como máximo en cada diccionario).
"""
import json
from datetime import date
from types import SimpleNamespace

import pytest

import main
from services import ai_router, chat_memory, openai_service, semantic_search_service

SECRET_A = "SECRET_A_ONLY_7F3C"
MESSAGE_B = "MESSAGE_B_ONLY_91D2"
CRM_A = "CRM_A_ONLY_4C81"
CRM_B = "CRM_B_ONLY_8A22"


# =====================================================================
# Doble de OpenAI
# =====================================================================

class FakeOpenAI:
    """
    Registra todas las llamadas (chat y embeddings) de los tres módulos.
    `router` decide la respuesta del router de intención a partir del mensaje
    del usuario; `summary` es el texto de los generadores de resúmenes.
    """

    def __init__(self):
        self.calls = []  # [{"module", "kind", "kwargs"}]
        self.router = lambda message: {"intent": "general", "client_name": None, "confidence": 95}
        self.router_raw = None       # texto crudo alternativo para el router
        self.summary = "Resumen generado por el modelo (simulado)"
        self.errors = {}             # {"router"|"summary"|"embedding": Exception}
        self.embedding = [1.0, 0.0, 0.0]

    def client_for(self, module):
        fake = self

        class _Completions:
            def create(self, **kwargs):
                return fake._chat(module, kwargs)

        class _Embeddings:
            def create(self, **kwargs):
                return fake._embed(module, kwargs)

        return SimpleNamespace(chat=SimpleNamespace(completions=_Completions()), embeddings=_Embeddings())

    def _chat(self, module, kwargs):
        kind = "router" if module == "ai_router" else "summary"
        self.calls.append({"module": module, "kind": kind, "kwargs": kwargs})
        if kind in self.errors:
            raise self.errors[kind]
        if kind == "router":
            content = self.router_raw if self.router_raw is not None else json.dumps(
                self.router(_router_message(kwargs)))
        else:
            content = self.summary
        return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=content))])

    def _embed(self, module, kwargs):
        self.calls.append({"module": module, "kind": "embedding", "kwargs": kwargs})
        if "embedding" in self.errors:
            raise self.errors["embedding"]
        return SimpleNamespace(data=[SimpleNamespace(embedding=list(self.embedding))])

    # --- inspección ---
    def sent_text(self, calls=None):
        """Todo el texto enviado a OpenAI (mensajes de chat e inputs de embeddings)."""
        parts = []
        for call in (self.calls if calls is None else calls):
            kw = call["kwargs"]
            parts.extend(m["content"] for m in kw.get("messages", []))
            if "input" in kw:
                parts.append(str(kw["input"]))
        return "\n".join(parts)

    def of_kind(self, kind):
        return [c for c in self.calls if c["kind"] == kind]


def _router_message(kwargs):
    prompt = kwargs["messages"][-1]["content"]
    return prompt.split("Mensaje:", 1)[1].strip().strip('"')


@pytest.fixture
def openai_fake(monkeypatch):
    fake = FakeOpenAI()
    monkeypatch.setattr(ai_router, "client", fake.client_for("ai_router"))
    monkeypatch.setattr(openai_service, "client", fake.client_for("openai_service"))
    monkeypatch.setattr(semantic_search_service, "client", fake.client_for("semantic_search_service"))
    return fake


def route(intent, client_name=None, confidence=95):
    return {"intent": intent, "client_name": client_name, "confidence": confidence}


def chat(client, user, message):
    response = client.post("/chat", json={"message": message}, headers=user["headers"])
    assert response.status_code == 200, response.text
    return response.json()


def during(fake, action):
    """Ejecuta `action` y devuelve solo las llamadas a OpenAI que produjo."""
    start = len(fake.calls)
    result = action()
    return result, fake.calls[start:]


# =====================================================================
# Datos CRM: catálogo global + actividades privadas marcadas
# =====================================================================

@pytest.fixture
def crm(factory, user_a, user_b):
    nebula = factory.client("Nebula Logística S.L.", alias="Nebula")
    orion = factory.client("Orion Consultoría S.L.", alias="Orion")
    reunion = factory.activity_type_id("Concertar reunión")
    today = date.today().isoformat()

    a_ids = [factory.activity(user_a["id"], nebula, activity_type_id=reunion,
                              datetime_iso=f"{today}T1{i}:00:00",
                              comentario=f"{CRM_A} visita {i} a Nebula",
                              embedding=[1.0, 0.0, 0.0]) for i in range(5)]
    b_ids = [factory.activity(user_b["id"], nebula, activity_type_id=reunion,
                              datetime_iso=f"{today}T0{i}:00:00",
                              comentario=f"{CRM_B} llamada {i} a Nebula",
                              embedding=[1.0, 0.0, 0.0]) for i in range(2)]
    b_ids += [factory.activity(user_b["id"], orion, activity_type_id=reunion,
                               datetime_iso=f"{today}T0{i}:30:00",
                               comentario=f"{CRM_B} Orion {i}",
                               embedding=[0.9, 0.1, 0.0]) for i in range(5)]

    # Facturación global de Nebula (sin propietario por diseño)
    import db
    conn = db.get_connection()
    product = conn.execute("INSERT INTO products (nombre, precio) VALUES ('Licencia Chat', 100)").lastrowid
    invoice = conn.execute("INSERT INTO invoices (fecha, client_id) VALUES ('2026-06-01', ?)", (nebula,)).lastrowid
    conn.execute("INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (?, ?, 3, 100, 300)",
                 (invoice, product))
    conn.commit()
    conn.close()
    return SimpleNamespace(nebula=nebula, orion=orion, a_ids=a_ids, b_ids=b_ids)


# =====================================================================
# D.6.1 AUTH (sin token / token inválido: ver test_auth.PROTECTED_ENDPOINTS)
# =====================================================================

def test_token_valido_entra_en_el_flujo_y_llega_al_router(client, user_a, openai_fake):
    body = chat(client, user_a, "hola")

    assert set(body) == {"type", "content", "metadata"}
    assert len(openai_fake.of_kind("router")) == 1


def test_sin_token_no_se_llama_a_openai(client, openai_fake):
    assert client.post("/chat", json={"message": SECRET_A}).status_code == 401
    assert openai_fake.calls == []


def test_token_de_usuario_inexistente_entra_en_el_flujo(client, openai_fake, jwt_factory):
    """
    Caracterización: /chat no comprueba que el comercial exista (solo firma y
    exp del JWT); la memoria se indexa igualmente por ese id.
    """
    token = jwt_factory(987654, "borrado@test.local")

    response = client.post("/chat", json={"message": "hola"}, headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 200


# =====================================================================
# D.6.2 MEMORIA DE CHAT (P0)
# =====================================================================

def test_memoria_no_guarda_texto_de_mensajes_solo_cliente_e_intencion(client, user_a, crm, openai_fake):
    openai_fake.router = lambda m: route("billing_query")
    chat(client, user_a, f"{SECRET_A} cuanto nos factura")

    memory_dump = repr(chat_memory._last_client_by_user) + repr(chat_memory._pending_intent_by_user)
    assert SECRET_A not in memory_dump
    assert chat_memory._pending_intent_by_user == {
        user_a["id"]: {"intent": "billing_query", "waiting_for": "client"},
    }


def test_el_prompt_del_router_solo_contiene_el_mensaje_actual(client, user_a, openai_fake):
    chat(client, user_a, f"primero {SECRET_A}")
    _, calls = during(openai_fake, lambda: chat(client, user_a, "segundo mensaje"))

    sent = openai_fake.sent_text(calls)
    assert "segundo mensaje" in sent
    assert SECRET_A not in sent  # sin historial: ni siquiera el propio usuario lo recibe


def test_secreto_de_a_nunca_llega_al_prompt_de_b(client, user_a, user_b, crm, openai_fake):
    openai_fake.router = lambda m: route("prepare_meeting", "Nebula")
    _, calls_a = during(openai_fake, lambda: chat(client, user_a, f"prepara reunión con Nebula {SECRET_A}"))
    _, calls_b = during(openai_fake, lambda: chat(client, user_b, f"prepara reunión con Nebula {MESSAGE_B}"))

    assert SECRET_A in openai_fake.sent_text(calls_a)
    assert MESSAGE_B in openai_fake.sent_text(calls_b)
    assert SECRET_A not in openai_fake.sent_text(calls_b)
    assert MESSAGE_B not in openai_fake.sent_text(calls_a)


def test_a_a_la_intencion_pendiente_propia_se_conserva(client, user_a, crm, openai_fake):
    openai_fake.router = lambda m: route("billing_query")
    first = chat(client, user_a, "cuánto factura")
    assert first == {"type": "billing_query", "content": "¿De qué cliente quieres consultar la facturación?",
                     "metadata": None}

    second, calls = during(openai_fake, lambda: chat(client, user_a, "Nebula"))
    assert second["type"] == "billing_summary"
    assert second["metadata"]["client_id"] == crm.nebula
    assert calls == []  # la respuesta pendiente se resuelve sin pasar por la IA
    assert chat_memory.get_pending_intent(user_a["id"]) is None
    assert chat_memory.get_last_client(user_a["id"]) == crm.nebula


def test_b_no_consume_la_intencion_pendiente_de_a(client, user_a, user_b, crm, openai_fake):
    openai_fake.router = lambda m: route("billing_query")
    chat(client, user_a, "cuánto factura")

    openai_fake.router = lambda m: route("general")
    _, calls_b = during(openai_fake, lambda: chat(client, user_b, "Nebula"))

    assert len([c for c in calls_b if c["kind"] == "router"]) == 1  # B pasa por la IA: no tenía pendiente
    assert chat_memory.get_pending_intent(user_a["id"]) == {"intent": "billing_query", "waiting_for": "client"}
    assert chat_memory.get_pending_intent(user_b["id"]) is None


def test_el_ultimo_cliente_de_a_no_se_usa_para_b(client, user_a, user_b, crm, openai_fake):
    openai_fake.router = lambda m: route("billing_query", "Nebula")
    chat(client, user_a, "facturación de Nebula")
    assert chat_memory.get_last_client(user_a["id"]) == crm.nebula

    openai_fake.router = lambda m: route("billing_query")
    body_b = chat(client, user_b, "y la facturación?")

    assert body_b["type"] == "billing_query"  # B tiene que decir el cliente
    assert body_b["metadata"] is None
    assert chat_memory.get_last_client(user_b["id"]) is None


def test_intercalado_a1_b1_a2_b2(client, user_a, user_b, crm, openai_fake):
    replies = {"A1": route("billing_query"), "B1": route("prepare_meeting")}
    openai_fake.router = lambda m: replies[m.split()[0]]

    a1 = chat(client, user_a, "A1 facturación")
    b1 = chat(client, user_b, "B1 preparar reunión")
    assert a1["type"] == "billing_query" and b1["type"] == "prepare_meeting"

    a2 = chat(client, user_a, "Nebula")
    b2, calls_b2 = during(openai_fake, lambda: chat(client, user_b, "Orion"))

    assert a2["type"] == "billing_summary" and a2["metadata"]["client_id"] == crm.nebula
    assert b2["type"] == "prepare_meeting" and b2["metadata"]["client_id"] == crm.orion
    summary_prompt = openai_fake.sent_text([c for c in calls_b2 if c["kind"] == "summary"])
    assert "Orion Consultoría S.L." in summary_prompt and CRM_B in summary_prompt
    assert CRM_A not in summary_prompt
    assert chat_memory.get_last_client(user_a["id"]) == crm.nebula
    assert chat_memory.get_last_client(user_b["id"]) == crm.orion
    assert chat_memory._pending_intent_by_user == {}


def test_memoria_sobrevive_entre_peticiones_y_no_hay_endpoint_de_reset(client, user_a, crm, openai_fake):
    openai_fake.router = lambda m: route("billing_query", "Nebula")
    chat(client, user_a, "facturación de Nebula")

    openai_fake.router = lambda m: route("billing_query")
    later = chat(client, user_a, "y ahora la facturación")  # sin cliente: usa el último

    assert later["type"] == "billing_summary" and later["metadata"]["client_id"] == crm.nebula
    chat_paths = {r.path for r in main.app.routes if "chat" in getattr(r, "path", "")}
    assert chat_paths == {"/chat"}


# =====================================================================
# D.6.3 AISLAMIENTO CRM en el contexto enviado al LLM
# =====================================================================

@pytest.mark.parametrize("intent,message", [
    ("prepare_meeting", "prepara la reunión con Nebula"),
    ("client_summary", "resumen del cliente Nebula"),
])
def test_contexto_del_llm_solo_con_actividades_del_usuario(client, user_a, user_b, crm, openai_fake,
                                                           intent, message):
    openai_fake.router = lambda m: route(intent, "Nebula")

    _, calls_a = during(openai_fake, lambda: chat(client, user_a, message))
    _, calls_b = during(openai_fake, lambda: chat(client, user_b, message))

    prompt_a = openai_fake.sent_text([c for c in calls_a if c["kind"] == "summary"])
    prompt_b = openai_fake.sent_text([c for c in calls_b if c["kind"] == "summary"])
    assert "Nebula Logística S.L." in prompt_a and "Nebula Logística S.L." in prompt_b
    assert CRM_A in prompt_a and CRM_B not in prompt_a
    assert CRM_B in prompt_b and CRM_A not in prompt_b
    assert "Total actividades: 5" in prompt_a or "Total actividades registradas: 5" in prompt_a
    assert "Total actividades: 2" in prompt_b or "Total actividades registradas: 2" in prompt_b


@pytest.mark.parametrize("confidence", [95, 10], ids=["ia", "fallback_por_palabras"])
def test_analiza_cliente_usa_client_summary_con_contexto_aislado(client, user_a, user_b, crm, openai_fake,
                                                                 confidence):
    """
    main normaliza client_analysis -> client_summary DESPUÉS del fallback, y la
    intención pendiente client_analysis solo se crea dentro de su propia rama:
    la rama client_analysis (generate_account_analysis) es inalcanzable hoy.
    """
    openai_fake.router = lambda m: route("client_analysis", "Nebula", confidence=confidence)

    _, calls_a = during(openai_fake, lambda: chat(client, user_a, "analiza cliente Nebula"))
    _, calls_b = during(openai_fake, lambda: chat(client, user_b, "analiza cliente Nebula"))

    prompt_a = openai_fake.sent_text([c for c in calls_a if c["kind"] == "summary"])
    prompt_b = openai_fake.sent_text([c for c in calls_b if c["kind"] == "summary"])
    # Se ejecutó generate_client_summary, no generate_account_analysis
    for prompt in (prompt_a, prompt_b):
        assert "consultor senior especializado en análisis de clientes" in prompt
        assert "Eres un analista CRM experto en cuentas B2B." not in prompt
    assert CRM_A in prompt_a and CRM_B not in prompt_a
    assert CRM_B in prompt_b and CRM_A not in prompt_b


def test_prepare_meeting_endpoint_contexto_aislado(client, user_a, user_b, crm, openai_fake):
    _, calls_a = during(openai_fake, lambda: client.post("/prepare-meeting", json={"client_id": crm.nebula},
                                                         headers=user_a["headers"]))
    _, calls_b = during(openai_fake, lambda: client.post("/prepare-meeting", json={"client_id": crm.nebula},
                                                         headers=user_b["headers"]))

    assert CRM_A in openai_fake.sent_text(calls_a) and CRM_B not in openai_fake.sent_text(calls_a)
    assert CRM_B in openai_fake.sent_text(calls_b) and CRM_A not in openai_fake.sent_text(calls_b)


def test_busqueda_semantica_del_chat_solo_devuelve_actividades_propias(client, user_a, user_b, crm, openai_fake):
    openai_fake.router = lambda m: route("semantic_search")

    results_a = chat(client, user_a, "de qué hablamos con Nebula")["metadata"]["results"]
    results_b = chat(client, user_b, "de qué hablamos con Nebula")["metadata"]["results"]

    assert results_a and {r["activity_id"] for r in results_a} <= set(crm.a_ids)
    assert results_b and {r["activity_id"] for r in results_b} <= set(crm.b_ids)
    assert all(CRM_B not in r["comentario"] for r in results_a)
    assert all(CRM_A not in r["comentario"] for r in results_b)


def test_crm_insights_por_usuario_regresion_b1(client, user_a, user_b, crm, openai_fake):
    openai_fake.router = lambda m: route("crm_insights")

    content_a = chat(client, user_a, "insights del CRM")["content"]
    content_b = chat(client, user_b, "insights del CRM")["content"]

    # A: 5 actividades en Nebula, ninguna en Orion. B: 2 en Nebula, 5 en Orion.
    assert "Nebula Logística S.L. tiene alta actividad" in content_a
    assert "Orion Consultoría S.L. no tiene actividad registrada" in content_a
    assert "Orion Consultoría S.L. tiene alta actividad" in content_b
    assert "Nebula Logística S.L. tiene alta actividad" not in content_b
    inactive_a = content_a.split("sin actividad reciente:")[1].split("Actividad comercial")[0]
    inactive_b = content_b.split("sin actividad reciente:")[1].split("Actividad comercial")[0]
    assert "Orion" in inactive_a and "Nebula" not in inactive_a
    assert "Orion" not in inactive_b and "Nebula" not in inactive_b
    # Ningún texto de actividades (privado) aparece en los insights
    for content in (content_a, content_b):
        assert CRM_A not in content and CRM_B not in content
    assert openai_fake.of_kind("summary") == []  # crm_insights no usa el LLM


def test_facturacion_es_global_por_diseno(client, user_a, user_b, crm, openai_fake):
    openai_fake.router = lambda m: route("billing_query", "Nebula")

    billing_a = chat(client, user_a, "facturación de Nebula")["metadata"]["billing"]
    billing_b = chat(client, user_b, "facturación de Nebula")["metadata"]["billing"]

    assert billing_a == billing_b
    assert billing_a["total_facturado"] == 300


# =====================================================================
# D.6.4 CONTRATO
# =====================================================================

def test_mensaje_no_entendido(client, user_a, openai_fake):
    assert chat(client, user_a, "qué tiempo hace") == {
        "type": "error", "content": "No he entendido la petición. Prueba de nuevo.", "metadata": None,
    }


@pytest.mark.parametrize("message", ["", "   "])
def test_mensaje_vacio_o_espacios_respuesta_controlada(client, user_a, openai_fake, message):
    body = chat(client, user_a, message)

    assert body["type"] == "error"


@pytest.mark.parametrize("body", [None, {}, {"message": None}, {"message": 123}, {"mensaje": "hola"}])
def test_body_invalido_422_sin_llamar_a_openai(client, user_a, openai_fake, body):
    response = client.post("/chat", json=body, headers=user_a["headers"])

    assert response.status_code == 422
    assert openai_fake.calls == []


def test_palabra_contexto_respuesta_fija(client, user_a, openai_fake):
    assert chat(client, user_a, "dame contexto") == {
        "type": "client_context", "content": "Buscando contexto del cliente...", "metadata": None,
    }


def test_respuesta_prepare_meeting_con_metadata(client, user_a, crm, openai_fake):
    openai_fake.router = lambda m: route("prepare_meeting", "Nebula")

    body = chat(client, user_a, "prepara reunión con Nebula")

    assert body["type"] == "prepare_meeting"
    assert body["content"] == openai_fake.summary
    assert body["metadata"] == {"client_id": crm.nebula,
                                "suggested_actions": ["client_summary", "billing_query", "semantic_search"]}


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B17: client_summary pendiente no se resuelve con la respuesta: vuelve a preguntar")
def test_b17_resumen_pendiente_se_resuelve_al_dar_el_cliente(client, user_a, crm, openai_fake):
    openai_fake.router = lambda m: route("client_summary")
    assert chat(client, user_a, "dame un resumen")["content"] == "¿De qué cliente quieres el resumen?"

    follow_up = chat(client, user_a, "Nebula")

    assert follow_up["content"] == "Resumen cliente"


# =====================================================================
# D.6.5 ERRORES DE OPENAI
# =====================================================================

def _openai_errors():
    import httpx
    import openai
    request = httpx.Request("POST", "http://127.0.0.1:9/v1/chat/completions")
    return {
        "conexion": openai.APIConnectionError(request=request),
        "timeout": openai.APITimeoutError(request=request),
        "generica": RuntimeError("Incorrect API key provided: sk-test-not-a-real-key"),
    }


@pytest.mark.parametrize("error", ["conexion", "timeout", "generica"])
def test_fallo_del_router_cae_al_detector_por_palabras(client, user_a, crm, openai_fake, error):
    openai_fake.errors["router"] = _openai_errors()[error]

    body = chat(client, user_a, "facturación de Nebula")

    assert body["type"] == "billing_summary"
    assert body["metadata"]["client_id"] == crm.nebula
    assert "sk-test" not in json.dumps(body)


@pytest.mark.parametrize("raw", ["", "no es json", "{json roto"])
def test_respuesta_inesperada_del_router_cae_al_detector_por_palabras(client, user_a, crm, openai_fake, raw):
    openai_fake.router_raw = raw

    body = chat(client, user_a, "facturación de Nebula")

    assert body["type"] == "billing_summary"


B20_ROUTER_OUTPUTS = {
    "confidence_null": json.dumps(route("billing_query", "Nebula", confidence=None)),
    "confidence_texto": json.dumps(route("billing_query", "Nebula", confidence="95")),
    "json_lista": '["lista"]',
}


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B20: la salida del router no se valida (confidence no numérica o JSON no objeto -> 500)")
@pytest.mark.parametrize("output", B20_ROUTER_OUTPUTS)
def test_b20_salida_inesperada_del_router_no_rompe_el_chat(client_no_raise, user_a, crm, openai_fake, output):
    openai_fake.router_raw = B20_ROUTER_OUTPUTS[output]

    response = client_no_raise.post("/chat", json={"message": "facturación de Nebula"}, headers=user_a["headers"])

    assert response.status_code == 200


@pytest.mark.parametrize("path", ["chat", "endpoint"])
def test_fallo_del_resumen_de_reunion_respuesta_controlada(client, user_a, crm, openai_fake, path):
    openai_fake.router = lambda m: route("prepare_meeting", "Nebula")
    openai_fake.errors["summary"] = _openai_errors()["timeout"]

    if path == "chat":
        response = client.post("/chat", json={"message": "reunión con Nebula"}, headers=user_a["headers"])
    else:
        response = client.post("/prepare-meeting", json={"client_id": crm.nebula}, headers=user_a["headers"])

    assert response.status_code == 200
    text = response.text
    assert "Error generando resumen" in text
    assert "Traceback" not in text and CRM_A not in text  # sin trazas ni el prompt interno


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B18: el texto de la excepción de OpenAI se devuelve al cliente (puede incluir la API key)")
@pytest.mark.parametrize("path", ["chat", "endpoint"])
def test_b18_error_de_openai_no_se_devuelve_al_cliente(client, user_a, crm, openai_fake, path):
    openai_fake.router = lambda m: route("prepare_meeting", "Nebula")
    openai_fake.errors["summary"] = _openai_errors()["generica"]

    if path == "chat":
        response = client.post("/chat", json={"message": "reunión con Nebula"}, headers=user_a["headers"])
    else:
        response = client.post("/prepare-meeting", json={"client_id": crm.nebula}, headers=user_a["headers"])

    assert "sk-test-not-a-real-key" not in response.text
    assert "Incorrect API key" not in response.text


FAILING_LLM_INTENTS = {
    "client_summary": (route("client_summary", "Nebula"), "resumen del cliente Nebula", "summary"),
    "semantic_search": (route("semantic_search"), "de qué hablamos con Nebula", "embedding"),
}


@pytest.mark.parametrize("intent", FAILING_LLM_INTENTS)
def test_fallo_de_openai_no_filtra_detalles_internos(client_no_raise, user_a, crm, openai_fake, intent):
    """
    Propiedad de seguridad que debe cumplirse hoy (500) y cuando B19 se
    corrija: sin clave, texto de la excepción, prompt ni trazas. El status
    NO se fija aquí: lo protege el xfail de B19.
    """
    reply, message, kind = FAILING_LLM_INTENTS[intent]
    openai_fake.router = lambda m: reply
    openai_fake.errors[kind] = _openai_errors()["generica"]

    response = client_no_raise.post("/chat", json={"message": message}, headers=user_a["headers"])

    assert openai_fake.of_kind(kind), "la llamada a OpenAI que falla debe haberse producido"
    text = response.text
    assert "sk-test-not-a-real-key" not in text      # API key
    assert "Incorrect API key" not in text           # texto de la excepción
    assert CRM_A not in text                         # contexto CRM del prompt
    assert "Eres un" not in text and "FACTURACIÓN" not in text  # prompt interno
    assert "Traceback" not in text and 'File "' not in text


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B19: fallos de OpenAI en client_summary/semantic_search no se capturan -> 500")
@pytest.mark.parametrize("intent", FAILING_LLM_INTENTS)
def test_b19_fallo_de_openai_respuesta_controlada(client_no_raise, user_a, crm, openai_fake, intent):
    reply, message, kind = FAILING_LLM_INTENTS[intent]
    openai_fake.router = lambda m: reply
    openai_fake.errors[kind] = _openai_errors()["timeout"]

    response = client_no_raise.post("/chat", json={"message": message}, headers=user_a["headers"])

    assert response.status_code != 500


# =====================================================================
# D.6.6 CRECIMIENTO DE LA MEMORIA
# =====================================================================

def test_memoria_acotada_a_una_entrada_por_usuario(client, user_a, user_b, crm, openai_fake):
    openai_fake.router = lambda m: route("billing_query", "Nebula" if "Nebula" in m else "Orion")
    for i in range(30):
        chat(client, user_a, f"facturación de {'Nebula' if i % 2 else 'Orion'} {i}")
        chat(client, user_b, f"facturación de Orion {i}")

    assert set(chat_memory._last_client_by_user) == {user_a["id"], user_b["id"]}
    assert chat_memory.get_last_client(user_a["id"]) == crm.nebula  # la última (i = 29)
    assert chat_memory.get_last_client(user_b["id"]) == crm.orion


def test_si_openai_falla_la_memoria_de_a_queda_intacta(client, user_a, user_b, crm, openai_fake):
    # 1. A deja estado conocido: último cliente Nebula + intención pendiente
    openai_fake.router = lambda m: route("billing_query", "Nebula")
    chat(client, user_a, "facturación de Nebula")
    openai_fake.router = lambda m: route("client_summary")
    chat(client, user_a, "dame un resumen")  # sin "cliente X": queda pendiente
    memory_a = (chat_memory.get_last_client(user_a["id"]), chat_memory.get_pending_intent(user_a["id"]))
    assert memory_a == (crm.nebula, {"intent": "client_summary", "waiting_for": "client"})

    # 2-3. B (sin intención pendiente) llega al router y OpenAI falla de verdad
    openai_fake.errors["router"] = RuntimeError("caída de OpenAI")
    body_b, calls_b = during(openai_fake, lambda: chat(client, user_b, "facturación de Orion"))

    # 4. El router se llamó (y lanzó la excepción): la petición de B pasó por la IA
    assert [c["kind"] for c in calls_b] == ["router"]
    # El chat de B siguió por el detector por palabras y actualizó SOLO la memoria de B
    assert body_b["type"] == "billing_summary" and body_b["metadata"]["client_id"] == crm.orion
    assert chat_memory.get_last_client(user_b["id"]) == crm.orion
    assert chat_memory.get_pending_intent(user_b["id"]) is None

    # 5. La memoria de A sigue intacta, sin datos de B
    assert (chat_memory.get_last_client(user_a["id"]), chat_memory.get_pending_intent(user_a["id"])) == memory_a
    assert set(chat_memory._last_client_by_user) == {user_a["id"], user_b["id"]}
    assert set(chat_memory._pending_intent_by_user) == {user_a["id"]}
