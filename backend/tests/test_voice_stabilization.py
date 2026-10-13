"""
Estabilización tras la batería manual de VOZ del Action Engine.

Cada caso usa una transcripción REAL de la batería y la salida que dio el
intérprete (simulado: products vacío, date_said ausente, emails con comas...),
para fijar que el backend determina lo correcto aunque el LLM falle:

1. CREATE_ACTIVITY: productos del catálogo mencionados en el texto.
2. Email dictado (CREATE_CLIENT y CREATE_CONTACT, mismo normalizador).
3. Teléfono: nunca se quitan cifras; uno raro se avisa para revisarlo.
4-5. Mayúsculas: solo valores enteros en minúscula; nombres nuevos no se adivinan.
6. Contacto ↔ cliente, ambigüedad y fuzzy contextual (sin regresiones).
7. Fechas y horas naturales relativas al `now` del backend.
+ DELETE_PRODUCT por voz NO existe: se rechaza.
H2_NOW = jueves 2026-10-01 09:00.
"""
import pytest
from pydantic import ValidationError

from conftest import H2_NOW, make_interpretation as interp
from core.relative_dates import resolve_day, resolve_time
from core.structured_values import normalize_email, normalize_phone, phone_review_message
from schemas.actions import Interpretation, NewClientMention, NewContactMention

CALL, MEETING = "Realizar llamada de seguimiento", "Concertar reunión"


@pytest.fixture
def run(client, user_a, interpreter, business_counts, frozen_now):
    def _run(interpretation, text):
        before = business_counts()
        interpreter.script(interpretation)
        response = client.post("/actions/interpret", json={"text": text}, headers=user_a["headers"])
        assert business_counts() == before, "¡Se ha escrito en el CRM antes de confirmar!"
        return response
    return _run


@pytest.fixture
def draft(run):
    def _draft(interpretation, text):
        response = run(interpretation, text)
        assert response.status_code == 201, response.json()
        return response.json()
    return _draft


@pytest.fixture
def patch(client, user_a):
    def _patch(d, edits):
        return client.patch(f"/actions/{d['id']}", json={"revision": d["revision"], "edits": edits},
                            headers=user_a["headers"]).json()
    return _patch


@pytest.fixture
def confirm(client, user_a):
    return lambda d: client.post(f"/actions/{d['id']}/confirm", json={"revision": d["revision"]},
                                 headers=user_a["headers"])


@pytest.fixture
def crm(factory, h2_crm):
    """h2_crm + lo que había en la batería real (Lucía Molina y más productos)."""
    h2_crm.lucia = factory.contact(h2_crm.sanlucas, "Lucia Molina")
    h2_crm.nube = factory.product("Teclado Nube", 29.0)
    h2_crm.mochila = factory.product("Mochila Costa", 49.0)
    h2_crm.campo = factory.product("Monitor Campo 27", 265.0, aliases=["campo 27", "monitor campo"])
    return h2_crm


def blocking(d):
    return [(i["field"], i["code"]) for i in d["issues"] if i["blocking"]]


def warnings(d):
    return [(i["field"], i["code"]) for i in d["issues"] if not i["blocking"]]


def product_ids(d):
    return [p["id"] for p in d["fields"]["products"]]


# =====================================================================
# 1. Productos omitidos en CREATE_ACTIVITY (el intérprete devolvió products = [])
# =====================================================================

def test_qa_lucia_instituto_alucas_raton_faro(draft, crm, confirm, dbq, fake_embedding):
    text = "Programa una reunión mañana a las seis de la tarde con Lucía del Instituto Alucas para hablar del ratón Faro."
    d = draft(interp(client_name="Instituto Alucas", contact_name="Lucía", activity_type=MEETING, date="2026-10-02",
                     date_said="mañana", time="18:00", status="pending", products=[],
                     comment="Hablar del ratón Faro"), text)
    f = d["fields"]
    assert (f["client"]["id"], f["client"]["match"]) == (crm.sanlucas, "fuzzy")      # coincidencia aproximada
    assert f["contact"]["id"] == crm.lucia
    assert product_ids(d) == [crm.raton]
    assert (f["date"], f["time"]) == ("2026-10-02", "18:00")
    assert f["comment"] == "Hablar del ratón Faro" and d["source_text"] == text      # texto original intacto
    assert d["confirmable"] is True
    assert confirm(d).status_code == 200
    assert dbq.one("SELECT product_id FROM activity_products")["product_id"] == crm.raton


def test_qa_carlos_teclado_nube_y_seleccion_del_contacto(draft, patch, confirm, crm, dbq, fake_embedding):
    text = "Programa una llamada pasado mañana a las doce con Carlos para hablar del teclado nube."
    d = draft(interp(contact_name="Carlos", activity_type=CALL, date="2026-10-03", date_said="pasado mañana",
                     time="12:00", status="pending", products=[], comment="Hablar del teclado nube"), text)
    assert product_ids(d) == [crm.nube]
    assert ("client", "missing") in blocking(d) and ("contact", "ambiguous") in blocking(d)
    candidates = next(i for i in d["issues"] if i["code"] == "ambiguous")["candidates"]
    assert {c["id"] for c in candidates} == {crm.carlos_p, crm.carlos_r}               # las dos opciones

    chosen = patch(d, {"contact_id": crm.carlos_r})
    assert chosen["fields"]["contact"]["match"] == "user_selected"
    assert (chosen["fields"]["client"]["id"], chosen["fields"]["client"]["match"]) == (crm.sanlucas, "inherited")
    assert blocking(chosen) == [] and chosen["confirmable"] is True                    # blockers recalculados
    assert product_ids(chosen) == [crm.nube]                                           # el producto no se pierde
    assert confirm(chosen).status_code == 200
    assert dbq.one("SELECT product_id FROM activity_products")["product_id"] == crm.nube


@pytest.mark.parametrize("phrase, key", [
    ("para hablar del Ratón Faro", "raton"),
    ("sobre el Teclado Nube", "nube"),
    ("para revisar el portátil Luna 13", "luna"),
    ("por el monitor Campo 27", "campo"),
    ("acerca de Mochila Costa", "mochila"),
    ("para hablar del portátil Campo 27", "campo"),
])
def test_formas_naturales_de_nombrar_un_producto(draft, crm, phrase, key):
    d = draft(interp(contact_name="Marta Lopez", activity_type=MEETING, date="2026-10-02", time="17:00",
                     status="pending", products=[], comment="Reunión"),
              f"Programa una reunión mañana a las 5 de la tarde con Marta López {phrase}.")
    assert product_ids(d) == [getattr(crm, key)]


def test_producto_creado_despues_tambien_se_reconoce(client, user_a, draft, crm):
    assert client.post("/products", json={"name": "Webcam Orbit", "price": "65"},
                       headers=user_a["headers"]).status_code == 201
    d = draft(interp(contact_name="Marta Lopez", activity_type=MEETING, date="2026-10-02", time="10:00",
                     status="pending", products=[]), "Reunión mañana con Marta López para enseñar la webcam orbit")
    assert [p["label"] for p in d["fields"]["products"]] == ["Webcam Orbit"]


def test_producto_mal_transcrito_no_se_inventa(draft, crm):
    # Batería real: "teclado nube" llegó como "teclado 9": no hay coincidencia segura
    d = draft(interp(contact_name="Carlos", activity_type=CALL, date="2026-10-03", time="12:00", status="pending",
                     products=[]), "Programa una llamada pasado mañana a las doce con Carlos para hablar del teclado 9")
    assert d["fields"]["products"] == []


def test_si_el_interprete_da_el_producto_el_resolver_hace_lo_de_siempre(draft, crm, factory):
    d = draft(interp(contact_name="Marta Lopez", activity_type=MEETING, date="2026-10-02", time="17:00",
                     status="pending", products=["portátil Campo 27"]),
              "Programa una reunión mañana a las 5 de la tarde con Marta López para hablar del portátil Campo 27.")
    [p] = d["fields"]["products"]
    assert (p["id"], p["said"], p["match"]) == (crm.campo, "portátil Campo 27", "fuzzy")
    assert ("products[0]", "fuzzy_match") in warnings(d)


# =====================================================================
# 2. Email dictado: el MISMO normalizador en CREATE_CLIENT y CREATE_CONTACT
# =====================================================================

QA_NOVA = ("CREA UN CLIENTE, llamado NOVA Digital, está en Elche, provincia de Alicante. El teléfono es 965432100 y "
           "el correo es CONTACTO, ARROBA NOVA digital.es. El cif es B54321876")


@pytest.mark.parametrize("said", ["CONTACTO, ARROBA NOVA digital.es", "CONTACTO, AROBA NOVA digital.es",
                                  "contacto, arroba nova digital.es", "contacto arroba novadigital punto es",
                                  "contacto a roba NOVA digital.es", "contacto; arroba novadigital: punto es."])
def test_email_dictado_con_pausas_y_variantes_del_asr(said):
    assert normalize_email(said) == "contacto@novadigital.es"


@pytest.mark.parametrize("said", ["contacto, nova digital", "contacto arroba", "contacto, arroba, arroba nova.es",
                                  "paula sanchez arroba nova punto es"])
def test_email_ambiguo_o_incompleto_no_se_inventa(said):
    assert normalize_email(said) == said


def nova_client(email="CONTACTO, ARROBA NOVA digital.es", phone="965432100", **extra):
    mention = dict(name="NOVA Digital", alias=None, city="Elche", province="Alicante", group_name=None,
                   phone=phone, email=email, cif="B54321876")
    mention.update(extra)
    return interp(action_type="create_client", new_client=NewClientMention(**mention))


def test_qa_create_client_nova_digital(draft, crm, confirm, dbq):
    d = draft(nova_client(), QA_NOVA)
    f = d["fields"]
    assert (f["name"], f["city"], f["province"]) == ("NOVA Digital", "Elche", "Alicante")
    assert (f["phone"], f["email"], f["cif"]) == ("965432100", "contacto@novadigital.es", "B54321876")
    assert d["confirmable"] is True and d["source_text"] == QA_NOVA
    assert confirm(d).status_code == 200
    assert dbq.one("SELECT email FROM clients WHERE razon_social = 'NOVA Digital'")["email"] == "contacto@novadigital.es"


@pytest.mark.parametrize("action", ["create_client", "create_contact"])
def test_mismo_normalizador_de_email_en_cliente_y_contacto(draft, crm, action):
    said = "CONTACTO, AROBA NOVA digital.es"
    it = nova_client(email=said) if action == "create_client" else interp(
        action_type="create_contact", client_name="Rivera",
        new_contact=NewContactMention(name="Nora Vidal", role=None, email=said, phone=None))
    d = draft(it, "dictado")
    assert d["fields"]["email"] == "contacto@novadigital.es" and d["confirmable"] is True


@pytest.mark.parametrize("action", ["create_client", "create_contact"])
def test_email_que_sigue_invalido_bloquea(draft, crm, action):
    said = "contacto, nova digital"
    it = nova_client(email=said) if action == "create_client" else interp(
        action_type="create_contact", client_name="Rivera",
        new_contact=NewContactMention(name="Nora Vidal", role=None, email=said, phone=None))
    d = draft(it, "dictado")
    assert d["fields"]["email"] == said and ("email", "invalid") in blocking(d) and d["confirmable"] is False


# =====================================================================
# 3. Teléfonos dictados: nunca se inventan ni se quitan cifras
# =====================================================================

@pytest.mark.parametrize("said, expected", [("965 432 100", "965432100"), ("965-432-100", "965432100"),
                                            ("9-6-5-4-3-2-1-0-0", "965432100"), ("965.43.21.00", "965432100")])
def test_telefono_solo_pierde_separadores(said, expected):
    assert normalize_phone(said) == expected


@pytest.mark.parametrize("said", ["9654321100", "965 432 1100", "96543210"])
def test_telefono_con_cifras_de_mas_o_de_menos_se_conserva(said):
    assert normalize_phone(said) == said                     # sin quitar ni añadir nada
    assert phone_review_message(normalize_phone(said)) is not None


@pytest.mark.parametrize("phone", ["965432100", "+34965432100", "+44 20 7946 0958", None, ""])
def test_telefono_correcto_o_internacional_no_avisa(phone):
    assert phone_review_message(phone) is None


def test_qa_telefono_con_un_digito_de_mas_se_muestra_para_revisar(draft, crm):
    # Batería real: "El teléfono es 9654321100" (la transcripción ya traía 10 cifras)
    d = draft(nova_client(phone="9654321100", email="contacto arroba novadigital punto es"), "dictado")
    assert d["fields"]["phone"] == "9654321100"
    assert ("phone", "invalid") in warnings(d)                # aviso visible, no bloquea
    assert d["confirmable"] is True
    message = next(i["message"] for i in d["issues"] if i["field"] == "phone")
    assert "10 cifras" in message


def test_telefono_raro_tambien_se_avisa_en_un_contacto(draft, crm):
    d = draft(interp(action_type="create_contact", client_name="Rivera", new_contact=NewContactMention(
        name="Nora Vidal", role=None, email=None, phone="61234567")), "dictado")
    assert d["fields"]["phone"] == "61234567" and ("phone", "invalid") in warnings(d)


# =====================================================================
# 4-5. Mayúsculas y nombres nuevos
# =====================================================================

def test_qa_academia_oasis_santa_pola_alicante(draft, crm):
    d = draft(interp(action_type="create_client", new_client=NewClientMention(
        name="academia oasis", alias=None, city="Santa Pola", province="alicante", group_name=None)),
        "crea un nuevo cliente llamado academia oasis en Santa Pola, alicante")
    f = d["fields"]
    assert (f["name"], f["city"], f["province"]) == ("Academia Oasis", "Santa Pola", "Alicante")


@pytest.mark.parametrize("name", ["NASA Academia", "NOVA Digital", "NOVA digital", "CRMVoice", "Tecnologia Rivera S.L."])
def test_casing_significativo_se_respeta(draft, crm, name):
    d = draft(interp(action_type="create_client", new_client=NewClientMention(
        name=name, alias=None, city="elche", province="ALICANTE", group_name=None)), "dictado")
    assert d["fields"]["name"] == name
    assert (d["fields"]["city"], d["fields"]["province"]) == ("Elche", "ALICANTE")


def test_email_y_cif_no_se_capitalizan(draft, crm):
    d = draft(nova_client(name="nova digital", email="Contacto@NovaDigital.ES"), "dictado")
    assert (d["fields"]["name"], d["fields"]["email"], d["fields"]["cif"]) == \
        ("Nova Digital", "contacto@novadigital.es", "B54321876")


def test_contacto_nuevo_conserva_lo_dictado(draft, crm):
    # "Laura" / "Paula" / "Helena": no se sustituye un nombre nuevo por uno parecido que exista
    d = draft(interp(action_type="create_contact", client_name="Rivera", new_contact=NewContactMention(
        name="paula lopez", role="responsable comercial", email=None, phone=None)), "dictado")
    assert (d["fields"]["name"], d["fields"]["role"]) == ("Paula Lopez", "Responsable comercial")
    assert "Marta" not in str(d["fields"])


# =====================================================================
# 6. Contacto ↔ cliente y fuzzy (sin regresiones)
# =====================================================================

def test_marta_lopez_exacta_y_cliente_deducido(draft, crm):
    d = draft(interp(contact_name="Marta López", activity_type=MEETING, date="2026-10-02", time="17:00",
                     status="pending"), "Programa una reunión mañana a las 5 con Marta López")
    f = d["fields"]
    assert (f["contact"]["id"], f["contact"]["match"]) == (crm.marta, "exact")
    assert (f["client"]["id"], f["client"]["match"]) == (crm.rivera, "inherited")     # «Deducido del contacto»
    assert d["confirmable"] is True


def test_instituto_alucas_con_su_contacto_es_aproximado(draft, crm):
    d = draft(interp(client_name="Instituto Alucas", contact_name="Lucía", activity_type=CALL, date="2026-10-02",
                     time="12:00", status="pending"), "Llama mañana a las doce a Lucía del Instituto Alucas")
    client = d["fields"]["client"]
    assert (client["id"], client["match"], client["said"]) == (crm.sanlucas, "fuzzy", "Instituto Alucas")
    assert ("client", "fuzzy_match") in warnings(d)


# =====================================================================
# 7. Fechas y horas naturales (relativas al now del backend)
# =====================================================================

@pytest.mark.parametrize("said, expected", [
    ("a las 5 de la tarde", "17:00"), ("a las cinco de la tarde", "17:00"), ("a las 6 de la tarde", "18:00"),
    ("a las seis de la tarde", "18:00"), ("a las doce", "12:00"), ("a las 12", "12:00"),
    ("a la 11 de la mañana", "11:00"), ("a las 9 y media de la mañana", "09:30"), ("a las 17", "17:00"),
    ("a la una del mediodía", "13:00"), ("a las 8 de la noche", "20:00"),
])
def test_horas_naturales(said, expected):
    assert resolve_time(f"Programa una reunión mañana {said} con Marta") == expected


@pytest.mark.parametrize("said", ["a las 5", "a las 11", "a las 10:30", "a las 5 o a las 6 de la tarde",
                                  "a las doce de la noche", "sin hora"])
def test_horas_ambiguas_no_se_deciden(said):
    assert resolve_time(said) is None


@pytest.mark.parametrize("text, llm_time, expected", [
    ("Programa una reunión mañana a las 5 de la tarde con Marta López", "05:00", "17:00"),   # el texto manda
    ("Programa una reunión mañana a las seis de la tarde con Marta López", None, "18:00"),
    ("Programa una llamada mañana a las doce con Marta López", "00:00", "12:00"),
    ("Programa una llamada mañana a las 11 con Marta López", "11:00", "11:00"),              # ambigua: el modelo
])
def test_la_hora_inequivoca_del_texto_manda(draft, crm, text, llm_time, expected):
    d = draft(interp(contact_name="Marta López", activity_type=CALL, date="2026-10-02", date_said="mañana",
                     time=llm_time, status="pending"), text)
    assert d["fields"]["time"] == expected


@pytest.mark.parametrize("said, expected", [
    ("mañana", "2026-10-02"), ("pasado mañana", "2026-10-03"), ("pasada mañana", "2026-10-03"),
    ("el sábado", "2026-10-03"), ("El Sábado", "2026-10-03"), ("este sábado", "2026-10-03"),
    ("el próximo sábado", "2026-10-03"), ("el sábado de la semana que viene", "2026-10-10"),
    ("el lunes", "2026-10-05"),
])
def test_fechas_relativas_a_la_fecha_del_backend(said, expected):
    assert resolve_day(said, H2_NOW.date()).isoformat() == expected


def test_qa_el_sabado_sin_date_said_se_lee_del_texto(draft, crm):
    # Batería real: el modelo NO copió date_said y propuso el día equivocado (jueves)
    text = "Programa una llamada El Sábado a las doce con Lucia de Institutos Alucas para hablar de Mochila Costa."
    d = draft(interp(client_name="Institutos Alucas", contact_name="Lucia", activity_type=CALL, date="2026-10-01",
                     date_said=None, time="12:00", status="pending", products=["Mochila Costa"]), text)
    assert (d["fields"]["date"], d["fields"]["time"]) == ("2026-10-03", "12:00")
    assert d["fields"]["client"]["id"] == crm.sanlucas and product_ids(d) == [crm.mochila]


def test_date_said_absoluto_mantiene_la_fecha_del_interprete(draft, crm):
    d = draft(interp(contact_name="Marta López", activity_type=CALL, date="2026-10-15", date_said="el 15 de octubre",
                     time="10:00", status="pending"), "Llama a Marta López el 15 de octubre, no mañana")
    assert d["fields"]["date"] == "2026-10-15"


def test_texto_con_dos_dias_no_se_decide_solo(draft, crm):
    d = draft(interp(contact_name="Marta López", activity_type=CALL, date="2026-10-05", date_said=None,
                     time="10:00", status="pending"), "Llama a Marta López mañana o el lunes a las 10")
    assert d["fields"]["date"] == "2026-10-05"                      # manda el intérprete


# =====================================================================
# DELETE_PRODUCT por voz NO existe
# =====================================================================

def test_eliminar_un_producto_por_voz_se_rechaza(run, crm, dbq):
    response = run(interp(action_type="unsupported", unsupported_reason="No puedo eliminar productos."),
                   "Elimina el producto Webcam Orbit")
    assert response.status_code == 422 and response.json()["issues"][0]["code"] == "unsupported"
    assert dbq.one("SELECT COUNT(*) AS n FROM action_drafts")["n"] == 0


def test_el_esquema_no_admite_delete_product():
    base = make_base()
    with pytest.raises(ValidationError):
        Interpretation.model_validate({**base, "action_type": "delete_product"})
    assert "delete_product" not in str(Interpretation.model_json_schema())


def make_base() -> dict:
    return interp().model_dump()
