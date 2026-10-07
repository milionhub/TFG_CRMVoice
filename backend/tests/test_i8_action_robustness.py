"""
I.8 (etapa 1) — Robustez del Action Engine tras la batería manual de voz.

1. CREATE_ACTIVITY: los productos del catálogo mencionados en el texto llegan
   al campo estructurado aunque el intérprete solo los pusiera en el
   comentario; ambigüedad -> elige el usuario; sin coincidencia segura -> nada.
2-3. Email, teléfono y CIF dictados (casos reales de Whisper).
4. Mayúsculas profesionales de datos NUEVOS sin destruir siglas ni marcas.
5. Una entidad nueva nunca se "corrige" por otra parecida que ya existe.
El intérprete (LLM) está simulado: se prueba lo determinista.
"""
import pytest

from conftest import make_interpretation as interp
from core.formats import capitalize_first, name_case
from core.structured_values import normalize_email, normalize_phone, normalize_tax_id
from schemas.actions import NewClientMention, NewContactMention

MEETING = "Concertar reunión"


@pytest.fixture
def run(client, user_a, interpreter, business_counts, frozen_now):
    def _run(interpretation, text="texto dictado"):
        before = business_counts()
        interpreter.script(interpretation)
        response = client.post("/actions/interpret", json={"text": text}, headers=user_a["headers"])
        assert business_counts() == before, "¡Se ha escrito en el CRM antes de confirmar!"
        assert response.status_code == 201, response.json()
        return response.json()

    return _run


@pytest.fixture
def patch(client, user_a):
    def _patch(draft, edits):
        return client.patch(f"/actions/{draft['id']}", json={"revision": draft["revision"], "edits": edits},
                            headers=user_a["headers"])
    return _patch


@pytest.fixture
def confirm(client, user_a):
    def _confirm(draft):
        return client.post(f"/actions/{draft['id']}/confirm", json={"revision": draft["revision"]},
                           headers=user_a["headers"])
    return _confirm


@pytest.fixture
def catalog(factory, h2_crm):
    """Productos de la batería real que no están en h2_crm."""
    return {
        "campo": factory.product("Monitor Campo 27", 265.0, aliases=["campo 27", "monitor campo"]),
        "nube": factory.product("Teclado Nube", 29.0),
        "mochila": factory.product("Mochila Costa", 49.0),
    }


def meeting(text_products=(), **fields):
    base = dict(contact_name="Marta Lopez", activity_type=MEETING, date="2026-10-02", time="17:00",
                status="pending", products=list(text_products), comment="Reunión para hablar del producto")
    base.update(fields)
    return interp(**base)


def ids(draft):
    return [p["id"] for p in draft["fields"]["products"]]


# =====================================================================
# 1. Productos en CREATE_ACTIVITY
# =====================================================================

QA_CAMPO = "Programa una reunión mañana a las 5 de la tarde con Marta López para hablar del portátil Campo 27."


def test_qa_producto_solo_en_el_comentario_llega_a_productos(run, h2_crm, catalog, confirm, dbq, fake_embedding):
    draft = run(meeting(comment="Reunión para hablar del portátil Campo 27"), QA_CAMPO)

    [product] = draft["fields"]["products"]
    assert product["id"] == catalog["campo"] and product["label"] == "Monitor Campo 27"
    assert draft["fields"]["contact"]["id"] == h2_crm.marta and draft["fields"]["client"]["id"] == h2_crm.rivera
    assert draft["fields"]["comment"] == "Reunión para hablar del portátil Campo 27"   # el texto natural se conserva
    assert draft["confirmable"] is True

    assert confirm(draft).status_code == 200
    assert dbq.one("SELECT product_id FROM activity_products")["product_id"] == catalog["campo"]


@pytest.mark.parametrize("text, key", [
    ("Llama a Marta López para hablar del Ratón Faro", "raton"),
    ("Reunión con Marta López para hablar del Teclado Nube", "nube"),
    ("reunión con marta lópez para hablar del TECLADO NUBE", "nube"),
    ("Reunión con Marta López para hablar del teclado nuve", "nube"),          # error leve del ASR
])
def test_producto_dicho_se_resuelve_con_mayusculas_tildes_y_errores_leves(run, h2_crm, catalog, text, key):
    expected = h2_crm.raton if key == "raton" else catalog[key]
    draft = run(meeting(), text)
    assert ids(draft) == [expected]


def test_varios_productos_del_texto(run, h2_crm, catalog):
    draft = run(meeting(), "Reunión con Marta López para hablar del Teclado Nube, el Ratón Faro y la Mochila Costa")
    assert set(ids(draft)) == {catalog["nube"], h2_crm.raton, catalog["mochila"]}


def test_no_se_duplica_lo_que_ya_dio_el_interprete(run, h2_crm, catalog):
    draft = run(meeting(["Ratón Faro"]), "Reunión con Marta López para hablar del Ratón Faro")
    assert ids(draft) == [h2_crm.raton]
    assert draft["fields"]["products"][0]["said"] == "Ratón Faro"


def test_mencion_sin_resolver_se_sustituye_por_el_producto_del_texto(run, h2_crm, catalog):
    draft = run(meeting(["portátil Campo 27"]), QA_CAMPO)
    [product] = draft["fields"]["products"]
    assert product["id"] == catalog["campo"] and product["said"] == "portátil Campo 27"
    assert product["match"] in ("fuzzy", "partial")                       # visible: «Has dicho …»
    assert not [i for i in draft["issues"] if i["field"].startswith("products") and i["blocking"]]


def test_producto_inexistente_no_se_inventa(run, h2_crm, catalog):
    draft = run(meeting(), "Reunión con Marta López para hablar del Portátil Orbe 16")
    assert draft["fields"]["products"] == []
    assert draft["confirmable"] is True                                    # la actividad no depende de ello


def test_mencion_inexistente_del_interprete_sigue_bloqueando(run, h2_crm, catalog):
    draft = run(meeting(["Portátil Orbe 16"]), "Reunión con Marta López para hablar del Portátil Orbe 16")
    [product] = draft["fields"]["products"]
    assert product["id"] is None and product["problem"] == "not_found" and draft["confirmable"] is False


def test_mismo_trozo_con_dos_productos_es_ambiguo(run, h2_crm, factory):
    nube = factory.product("Teclado Nube", 29.0, aliases=["nube pro"])
    raton_nube = factory.product("Raton Nube", 25.0, aliases=["nube pro"])
    draft = run(meeting(), "Reunión con Marta López para hablar del Nube Pro")
    [product] = draft["fields"]["products"]
    assert product["problem"] == "ambiguous" and {c["id"] for c in product["candidates"]} == {nube, raton_nube}
    assert draft["confirmable"] is False


def test_el_nombre_del_cliente_no_cuenta_como_producto(run, h2_crm, factory, catalog):
    factory.client("Teclado Nube Distribuciones")
    draft = run(meeting(client_name="Teclado Nube", contact_name=None), "Llama a Teclado Nube mañana a las 5")
    assert draft["fields"]["products"] == []


def test_venta_sigue_resolviendo_sus_productos_igual(run, h2_crm):
    from schemas.actions import SaleLineMention
    draft = run(interp(action_type="create_sale", client_name="Rivera", sale_lines=[
        SaleLineMention(product_name="Luna 13", concept=None, quantity=2, amount="1580", amount_is_unit_price=False),
        SaleLineMention(product_name="Ratón Faro", concept=None, quantity=3, amount="22", amount_is_unit_price=True),
    ]), "Vendí a Rivera 2 Luna 13 por 1580 y 3 ratones faro a 22 cada uno")
    lines = draft["fields"]["lines"]
    assert [line["product"]["id"] for line in lines] == [h2_crm.luna, h2_crm.raton]
    assert [line["amount_cents"] for line in lines] == [158000, 6600] and draft["confirmable"] is True


# =====================================================================
# 2-3. Email, teléfono y CIF dictados
# =====================================================================

@pytest.mark.parametrize("said, expected", [
    ("paulaarrobaconstruccionesmediterráneo.es", "paula@construccionesmediterraneo.es"),   # Whisper real
    ("contacto a roba NOVA digital.es", "contacto@novadigital.es"),                        # Whisper real
    ("Helena.Torresarroba valle alto.es", "helena.torres@vallealto.es"),                   # Whisper real
    ("contacto arroba novadigital punto es", "contacto@novadigital.es"),
    ("helena punto torres arroba valle alto punto es", "helena.torres@vallealto.es"),
    ("paula arroba construcciones mediterraneo punto es", "paula@construccionesmediterraneo.es"),
    ("info arroba empresa dot com.", "info@empresa.com"),
    ("«ana@empresa.es».", "ana@empresa.es"),
])
def test_email_dictado_qa(said, expected):
    assert normalize_email(said) == expected


@pytest.mark.parametrize("said", ["esto no es un email", "a roba", "arroba punto es", "ana arroba", "a@b@c.es",
                                  "paula sanchez arroba empresa punto es"])
def test_email_basura_no_se_acepta(said):
    assert normalize_email(said) == said           # tal cual: la validación normal lo rechazará


def test_email_qa_en_alta_de_contacto_y_cliente(run, h2_crm):
    contact = run(interp(action_type="create_contact", client_name="Rivera", new_contact=NewContactMention(
        name="Helena Torres", role=None, email="Helena.Torresarroba valle alto.es", phone=None)))
    assert contact["fields"]["email"] == "helena.torres@vallealto.es" and contact["confirmable"] is True

    client = run(interp(action_type="create_client", new_client=NewClientMention(
        name="Nova Digital", alias=None, city=None, province=None, group_name=None,
        email="contacto a roba NOVA digital.es")))
    assert client["fields"]["email"] == "contacto@novadigital.es" and client["confirmable"] is True


@pytest.mark.parametrize("action", ["create_contact", "create_client"])
def test_email_invalido_tras_normalizar_bloquea(run, h2_crm, action):
    if action == "create_contact":
        it = interp(action_type=action, client_name="Rivera", new_contact=NewContactMention(
            name="Helena Torres", role=None, email="helena arroba", phone=None))
    else:
        it = interp(action_type=action, new_client=NewClientMention(
            name="Nova Digital", alias=None, city=None, province=None, group_name=None, email="helena arroba"))
    draft = run(it)
    assert ("email", "invalid", True) in {(i["field"], i["code"], i["blocking"]) for i in draft["issues"]}
    assert draft["confirmable"] is False


@pytest.mark.parametrize("said, expected", [("965 12 34 56", "965123456"), ("6 1 1 - 2 3 4 - 5 6 7", "611234567"),
                                            ("611 234 56", "611 234 56"), ("12345", "12345")])
def test_telefono_solo_representaciones_inequivocas(said, expected):
    assert normalize_phone(said) == expected


@pytest.mark.parametrize("said, expected", [("b54321678", "B54321678"), ("B-54 321 678", "B54321678"),
                                            ("x1234567l", "X1234567L"), ("B5432167", "B5432167")])
def test_cif_casing_y_separadores(said, expected):
    assert normalize_tax_id(said) == expected


# =====================================================================
# 4. Mayúsculas profesionales (centralizado en core.formats)
# =====================================================================

@pytest.mark.parametrize("said, expected", [
    ("academia oasis", "Academia Oasis"), ("santa pola", "Santa Pola"), ("alicante", "Alicante"), ("elche", "Elche"),
    ("ayuntamiento de valle alto", "Ayuntamiento de Valle Alto"), ("maría josé de la fuente", "María José de la Fuente"),
    ("rivera sl", "Rivera SL"), ("tecnologia rivera s.l.", "Tecnologia Rivera S.L."),
    # Con alguna mayúscula se respeta TAL CUAL (casing significativo; regla de la estabilización)
    ("NASA academia", "NASA academia"), ("NOVA digital", "NOVA digital"), ("NOVA Digital", "NOVA Digital"),
    ("CRMVoice", "CRMVoice"), ("IT soluciones", "IT soluciones"), ("Santa Pola", "Santa Pola"),
    ("iPhone", "iPhone"), ("SL", "SL"), ("S.L.", "S.L."), ("castilla-la mancha", "Castilla-La Mancha"),
    ("portatil luna 13", "Portatil Luna 13"), ("3 cantos", "3 Cantos"), ("", ""), (None, None),
])
def test_name_case(said, expected):
    assert name_case(said) == expected


def test_cargo_sigue_siendo_tipo_frase():
    assert capitalize_first("responsable comercial") == "Responsable comercial"
    assert name_case("responsable comercial") == "Responsable Comercial"   # por eso NO se usa en cargos


def test_alta_de_cliente_qa_con_mayusculas_profesionales(run, h2_crm):
    draft = run(interp(action_type="create_client", new_client=NewClientMention(
        name="academia oasis", alias="oasis", city="elche", province="alicante", group_name=None,
        email="INFO arroba academiaoasis punto es", cif="b 54 321 678", phone="965 123 456")))
    fields = draft["fields"]
    assert (fields["name"], fields["alias"], fields["city"], fields["province"]) == \
        ("Academia Oasis", "Oasis", "Elche", "Alicante")
    assert (fields["email"], fields["cif"], fields["phone"]) == ("info@academiaoasis.es", "B54321678", "965123456")


def test_alta_de_cliente_respeta_siglas_y_marcas(run, h2_crm):
    draft = run(interp(action_type="create_client", new_client=NewClientMention(
        name="NASA academia", alias="CRMVoice", city=None, province=None, group_name=None)))
    assert (draft["fields"]["name"], draft["fields"]["alias"]) == ("NASA academia", "CRMVoice")


def test_alta_de_contacto_con_mayusculas_profesionales(run, h2_crm):
    draft = run(interp(action_type="create_contact", client_name="Rivera", new_contact=NewContactMention(
        name="paula sánchez", role="responsable comercial", email=None, phone=None)))
    assert (draft["fields"]["name"], draft["fields"]["role"]) == ("Paula Sánchez", "Responsable comercial")


def test_lo_que_escribe_el_usuario_en_la_revision_se_respeta(run, h2_crm, patch):
    draft = run(interp(action_type="create_client", new_client=NewClientMention(
        name="academia oasis", alias=None, city=None, province=None, group_name=None)))
    edited = patch(draft, {"name": "academia OASIS de idiomas"}).json()
    assert edited["fields"]["name"] == "academia OASIS de idiomas"


# =====================================================================
# 5. Una entidad NUEVA no se adivina
# =====================================================================

def test_cliente_nuevo_no_se_cambia_por_uno_parecido(run, h2_crm, factory, confirm, dbq):
    horizonte = factory.client("Academia Horizonte")
    draft = run(interp(action_type="create_client", new_client=NewClientMention(
        name="academia oasis", alias=None, city=None, province=None, group_name=None)),
        "Crea un cliente llamado academia oasis")
    assert draft["fields"]["name"] == "Academia Oasis"
    assert "Horizonte" not in str(draft["fields"])
    assert confirm(draft).status_code == 200
    names = {r["razon_social"] for r in dbq.all("SELECT razon_social FROM clients")}
    assert {"Academia Oasis", "Academia Horizonte"} <= names
    assert dbq.one("SELECT razon_social FROM clients WHERE id = ?", (horizonte,))["razon_social"] == "Academia Horizonte"


def test_contacto_nuevo_no_se_resuelve_contra_uno_existente(run, h2_crm):
    draft = run(interp(action_type="create_contact", client_name="Rivera", new_contact=NewContactMention(
        name="marta lopes", role=None, email=None, phone=None)))
    assert draft["fields"]["name"] == "Marta Lopes"          # no se convierte en "Marta Lopez"
