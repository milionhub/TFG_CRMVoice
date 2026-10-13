"""
I.7 — Voice V2: lenguaje natural y resolución de entidades.

Reproduce (conceptualmente) los casos del QA y sus vecinos, positivos y
CONSERVADORES:
  A. CREATE_CONTACT: teléfono/email dictados -> normalizados; lo ambiguo no se inventa.
  B. CREATE_CLIENT: teléfono/email/CIF llegan al borrador, se editan, se
     validan y se guardan al confirmar.
  C. Contacto ↔ cliente: elegir un contacto deduce su cliente; un cliente
     firme no se sobrescribe; cambiar el cliente revalida el contacto.
  D. Fuzzy + contexto: "Lucía de Institutos Alucas" se resuelve SOLO si la
     combinación de evidencias es inequívoca.
  E. Fechas relativas con fecha base fija.
  F. Garantías del Action Engine intactas.
El intérprete (LLM) está simulado: se prueba lo determinista.
"""
from datetime import date, datetime

import pytest

from conftest import make_interpretation as interp
from core.relative_dates import calendar_context, resolve_day
from core.structured_values import normalize_email, normalize_phone, normalize_tax_id
from schemas.actions import NewClientMention, NewContactMention
from services.actions import interpreter as interpreter_module

CALL = "Realizar llamada de seguimiento"


@pytest.fixture
def run(client, user_a, interpreter, business_counts, frozen_now):
    """Interpreta con la interpretación programada; comprueba que no se escribe nada antes de confirmar."""

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
    def _patch(draft, edits, *, revision=None):
        return client.patch(f"/actions/{draft['id']}", json={"revision": revision or draft["revision"],
                                                               "edits": edits}, headers=user_a["headers"])
    return _patch


@pytest.fixture
def confirm(client, user_a):
    def _confirm(draft, *, revision=None):
        return client.post(f"/actions/{draft['id']}/confirm", json={"revision": revision or draft["revision"]},
                           headers=user_a["headers"])
    return _confirm


def issues_of(draft):
    return {(i["field"], i["code"], i["blocking"]) for i in draft["issues"]}


def call(**fields):
    """Llamada pendiente completa salvo cliente/contacto (lo que se prueba)."""
    base = dict(activity_type=CALL, date="2026-10-03", time="11:00", status="pending", comment="Llamada")
    base.update(fields)
    return interp(**base)


# =====================================================================
# A. Normalización determinista de valores estructurados
# =====================================================================

@pytest.mark.parametrize("said", ["611 234 567", "611-234-567", "6-1-1-2-3-4-5-6-7", "611.234.567",
                                  "6 1 1 2 3 4 5 6 7", "seis uno uno dos tres cuatro cinco seis siete"])
def test_telefono_dictado_se_normaliza(said):
    assert normalize_phone(said) == "611234567"


@pytest.mark.parametrize("said", ["+34 611 234 567", "0034 611 234 567", "(+34) 611-234-567"])
def test_telefono_con_prefijo_lo_conserva(said):
    assert normalize_phone(said) == "+34611234567"


@pytest.mark.parametrize("said", ["611 23 45", "611 234 567 o 622 111 222", "seiscientos once", "llámame"])
def test_telefono_ambiguo_no_se_inventa(said):
    assert normalize_phone(said) == said          # tal cual: la validación decide


@pytest.mark.parametrize("said, expected", [
    ("paula arroba construccionesmediterraneo punto es", "paula@construccionesmediterraneo.es"),
    ("paulaarrobaconstruccionesmediterráneo.es", "paula@construccionesmediterraneo.es"),   # QA (Whisper)
    ("contacto arroba nasaacademia punto es", "contacto@nasaacademia.es"),
    ("paula arroba construcciones mediterraneo punto es", "paula@construccionesmediterraneo.es"),
    ("paula punto sanchez arroba empresa punto es", "paula.sanchez@empresa.es"),
    ("ana guion bajo lopez arroba empresa punto com", "ana_lopez@empresa.com"),
    ("info arroba empresapuntoes", "info@empresa.es"),
    ("Paula@Empresa.ES", "paula@empresa.es"),
])
def test_email_dictado_se_normaliza(said, expected):
    assert normalize_email(said) == expected


@pytest.mark.parametrize("said", [
    "paula sanchez arroba empresa punto es",      # ¿paula.sanchez, paula_sanchez o paulasanchez?
    "paula arroba empresa arroba otra punto es",  # dos arrobas
    "paula arroba empresa",                       # sin dominio de primer nivel
    "no lo tengo",
])
def test_email_ambiguo_no_se_inventa(said):
    assert normalize_email(said) == said


@pytest.mark.parametrize("said, expected", [("B 54 321 678", "B54321678"), ("b-54.321.678", "B54321678"),
                                            ("12345678 z", "12345678Z"), ("X 1234567 L", "X1234567L")])
def test_cif_nif_dictado_se_normaliza(said, expected):
    assert normalize_tax_id(said) == expected


@pytest.mark.parametrize("said", ["B 5432", "ABC 123", "I 1234567 8"])
def test_cif_no_reconocible_se_deja_tal_cual(said):
    assert normalize_tax_id(said) == said


def test_crear_contacto_qa_normaliza_telefono_y_email(run, h2_crm, confirm, dbq):
    text = ("Añade a Paula Sánchez como contacto de Rivera. Es responsable de administración, su teléfono es "
            "6-1-1-2-3-4-5-6-7 y su email es paulaarrobaconstruccionesmediterráneo.es")
    draft = run(interp(action_type="create_contact", client_name="Rivera", new_contact=NewContactMention(
        name="Paula Sánchez", role="responsable de administración", email="paulaarrobaconstruccionesmediterráneo.es",
        phone="6-1-1-2-3-4-5-6-7")), text)

    fields = draft["fields"]
    assert (fields["phone"], fields["email"]) == ("611234567", "paula@construccionesmediterraneo.es")
    assert fields["name"] == "Paula Sánchez"                     # los nombres no se tocan
    assert draft["source_text"] == text                          # la transcripción original se conserva
    assert draft["confirmable"] is True

    assert confirm(draft).status_code == 200
    row = dbq.one("SELECT telefono, email FROM contacts WHERE nombre = 'Paula Sánchez'")
    assert (row["telefono"], row["email"]) == ("611234567", "paula@construccionesmediterraneo.es")


def test_crear_contacto_email_ambiguo_bloquea_sin_inventar(run, h2_crm):
    draft = run(interp(action_type="create_contact", client_name="Rivera", new_contact=NewContactMention(
        name="Paula Sánchez", role=None, email="paula sanchez arroba empresa punto es", phone=None)))

    assert draft["fields"]["email"] == "paula sanchez arroba empresa punto es"
    assert ("email", "invalid", True) in issues_of(draft) and draft["confirmable"] is False


def test_normalizacion_no_toca_nombres_ni_texto_libre(run, h2_crm):
    draft = run(interp(action_type="create_contact", client_name="Rivera", new_contact=NewContactMention(
        name="Paula arroba Punto", role="jefa de obra 611 234 567", email=None, phone=None)))
    assert draft["fields"]["name"] == "Paula arroba Punto"
    assert draft["fields"]["role"] == "Jefa de obra 611 234 567"


# =====================================================================
# B. CREATE_CLIENT conserva teléfono, email y CIF
# =====================================================================

def nasa(**extra):
    mention = dict(name="NASA Academia", alias=None, city="Alicante", province="Alicante", group_name=None,
                   phone="965 123 456", email="contacto arroba nasaacademia punto es", cif="B 54 321 678")
    mention.update(extra)
    return interp(action_type="create_client", new_client=NewClientMention(**mention))


def test_crear_cliente_qa_llegan_telefono_email_y_cif(run, h2_crm, confirm, dbq):
    draft = run(nasa(), "Crea un nuevo cliente llamado NASA Academia, en Alicante, con teléfono 965 123 456, "
                        "email contacto arroba nasaacademia punto es y CIF B 54 321 678.")

    fields = draft["fields"]
    assert (fields["phone"], fields["email"], fields["cif"]) == ("965123456", "contacto@nasaacademia.es", "B54321678")
    assert draft["confirmable"] is True and not [i for i in draft["issues"] if i["blocking"]]

    response = confirm(draft)
    assert response.status_code == 200
    assert response.json()["result"]["data"]["cif"] == "B54321678"
    row = dbq.one("SELECT telefono, email, cif FROM clients WHERE razon_social = 'NASA Academia'")
    assert (row["telefono"], row["email"], row["cif"]) == ("965123456", "contacto@nasaacademia.es", "B54321678")


def test_crear_cliente_los_datos_sobreviven_a_un_patch_y_se_editan(run, h2_crm, patch, confirm, dbq):
    draft = run(nasa())

    renamed = patch(draft, {"name": "NASA Academia Alicante"}).json()
    assert (renamed["fields"]["phone"], renamed["fields"]["email"], renamed["fields"]["cif"]) == \
        ("965123456", "contacto@nasaacademia.es", "B54321678")

    edited = patch(renamed, {"phone": "966-000-111", "email": "Info@NasaAcademia.es", "cif": "b-12345678"}).json()
    assert (edited["fields"]["phone"], edited["fields"]["email"], edited["fields"]["cif"]) == \
        ("966000111", "info@nasaacademia.es", "B12345678")

    assert confirm(edited).status_code == 200
    row = dbq.one("SELECT razon_social, telefono, email, cif FROM clients WHERE cif = 'B12345678'")
    assert (row["razon_social"], row["telefono"], row["email"], row["cif"]) == \
        ("NASA Academia Alicante", "966000111", "info@nasaacademia.es", "B12345678")


def test_crear_cliente_email_invalido_bloquea(run, h2_crm, patch, confirm, dbq):
    draft = run(nasa(email="contacto arroba nasaacademia"))
    assert draft["fields"]["email"] == "contacto arroba nasaacademia"
    assert ("email", "invalid", True) in issues_of(draft) and draft["confirmable"] is False
    assert confirm(draft).status_code == 422
    assert dbq.one("SELECT COUNT(*) AS n FROM clients WHERE razon_social = 'NASA Academia'")["n"] == 0

    fixed = patch(draft, {"email": "contacto arroba nasaacademia punto es"}, revision=draft["revision"] + 1).json()
    assert fixed["fields"]["email"] == "contacto@nasaacademia.es" and fixed["confirmable"] is True


def test_crear_cliente_telefono_invalido_bloquea(run, h2_crm):
    draft = run(nasa(phone="nueve seis cinco abc"))
    assert ("phone", "invalid", True) in issues_of(draft) and draft["confirmable"] is False


def test_crear_cliente_cif_no_reconocible_avisa_sin_bloquear(run, h2_crm):
    draft = run(nasa(cif="B 5432"))
    assert draft["fields"]["cif"] == "B 5432"
    assert ("cif", "invalid", False) in issues_of(draft) and draft["confirmable"] is True


def test_crear_cliente_sin_datos_de_contacto_sigue_igual(run, h2_crm):
    draft = run(interp(action_type="create_client", new_client=NewClientMention(
        name="Cliente Sin Datos", alias=None, city=None, province=None, group_name=None)))
    assert (draft["fields"]["phone"], draft["fields"]["email"], draft["fields"]["cif"]) == (None, None, None)
    assert draft["confirmable"] is True


def test_el_esquema_del_interprete_pide_los_datos_del_cliente():
    schema = interpreter_module._SCHEMA
    new_client = next(d for d in schema["$defs"].values() if d.get("title") == "NewClientMention")
    assert {"phone", "email", "cif"} <= set(new_client["required"])
    assert "date_said" in schema["required"]


# =====================================================================
# C. Contacto ↔ cliente
# =====================================================================

def test_dos_carlos_siguen_pidiendo_eleccion(run, h2_crm):
    draft = run(call(contact_name="Carlos"))
    [ambiguous] = [i for i in draft["issues"] if i["code"] == "ambiguous"]
    assert {c["id"] for c in ambiguous["candidates"]} == {h2_crm.carlos_p, h2_crm.carlos_r}
    assert draft["fields"]["client"] is None and draft["confirmable"] is False


def test_qa_elegir_el_contacto_deduce_su_cliente(run, h2_crm, patch, confirm, dbq, fake_embedding):
    draft = run(call(contact_name="Carlos"), "Programa una llamada pasado mañana a las 11 con Carlos")

    chosen = patch(draft, {"contact_id": h2_crm.carlos_r}).json()

    assert chosen["fields"]["contact"]["id"] == h2_crm.carlos_r
    assert chosen["fields"]["contact"]["match"] == "user_selected"            # "Elegido por ti"
    assert chosen["fields"]["client"] == {**chosen["fields"]["client"], "id": h2_crm.sanlucas,
                                          "label": "Instituto San Lucas", "match": "inherited"}  # "Deducido del contacto"
    assert not any(i["field"] == "client" and i["blocking"] for i in chosen["issues"])
    assert chosen["confirmable"] is True

    assert confirm(chosen).status_code == 200
    row = dbq.one("SELECT client_id, contact_id FROM activities")
    assert (row["client_id"], row["contact_id"]) == (h2_crm.sanlucas, h2_crm.carlos_r)


def test_contacto_unico_deduce_su_cliente(run, h2_crm):
    draft = run(call(contact_name="Laura"))
    assert draft["fields"]["client"]["id"] == h2_crm.costa and draft["fields"]["client"]["match"] == "inherited"
    assert draft["confirmable"] is True


def test_cambiar_de_contacto_vuelve_a_deducir_un_cliente_deducido(run, h2_crm, patch):
    draft = run(call(contact_name="Carlos"))
    first = patch(draft, {"contact_id": h2_crm.carlos_r}).json()
    second = patch(first, {"contact_id": h2_crm.carlos_p}).json()
    assert second["fields"]["client"]["id"] == h2_crm.rivera and second["fields"]["client"]["match"] == "inherited"
    assert second["confirmable"] is True


def test_contacto_de_otro_cliente_no_sobrescribe_un_cliente_dicho(run, h2_crm, patch):
    draft = run(call(client_name="Rivera", contact_name="Marta"))
    chosen = patch(draft, {"contact_id": h2_crm.carlos_r}).json()

    assert chosen["fields"]["client"]["id"] == h2_crm.rivera and chosen["fields"]["client"]["match"] == "exact"
    assert ("contact", "conflict", True) in issues_of(chosen) and chosen["confirmable"] is False


def test_contacto_de_otro_cliente_no_sobrescribe_un_cliente_elegido(run, h2_crm, patch):
    draft = run(call(contact_name="Carlos"))
    client_chosen = patch(draft, {"client_id": h2_crm.costa}).json()
    chosen = patch(client_chosen, {"contact_id": h2_crm.carlos_r}).json()
    assert chosen["fields"]["client"]["id"] == h2_crm.costa
    assert ("contact", "conflict", True) in issues_of(chosen) and chosen["confirmable"] is False


def test_cambiar_el_cliente_vuelve_a_resolver_el_contacto_dentro(run, h2_crm, patch):
    draft = run(call(client_name="Rivera", contact_name="Marta"))
    assert draft["fields"]["contact"]["id"] == h2_crm.marta

    moved = patch(draft, {"client_id": h2_crm.costa}).json()
    # "Marta" dicho -> la Marta de Diputacion Costa Verde, no la de Rivera
    assert moved["fields"]["contact"]["id"] == h2_crm.marta_r and moved["confirmable"] is True


def test_cambiar_el_cliente_invalida_un_contacto_incompatible(run, h2_crm, patch):
    draft = run(call(client_name="Rivera", contact_name="Carlos Perez"))
    moved = patch(draft, {"client_id": h2_crm.costa}).json()

    contact = moved["fields"]["contact"]
    assert contact["id"] is None and contact["problem"] == "conflict"       # "No encaja": nunca en silencio
    assert ("contact", "conflict", True) in issues_of(moved) and moved["confirmable"] is False


def test_elegir_cliente_resuelve_un_contacto_ambiguo(run, h2_crm, patch):
    draft = run(call(contact_name="Carlos"))
    chosen = patch(draft, {"client_id": h2_crm.sanlucas}).json()
    assert chosen["fields"]["contact"]["id"] == h2_crm.carlos_r and chosen["confirmable"] is True


def test_la_seleccion_manual_persiste(run, h2_crm, patch, client, user_a):
    draft = run(call(contact_name="Carlos"))
    chosen = patch(draft, {"contact_id": h2_crm.carlos_r}).json()
    stored = client.get(f"/actions/{draft['id']}", headers=user_a["headers"]).json()
    assert stored["fields"] == chosen["fields"] and stored["revision"] == chosen["revision"]


# =====================================================================
# D. Fuzzy + contexto
# =====================================================================

@pytest.fixture
def lucia(factory, h2_crm):
    return factory.contact(h2_crm.sanlucas, "Lucia Molina")


def test_qa_lucia_de_institutos_alucas_se_resuelve_por_contexto(run, h2_crm, lucia):
    draft = run(call(client_name="Institutos Alucas", contact_name="Lucía", products=[]),
                "Programa una llamada el sábado a las doce con Lucía de Institutos Alucas")

    client, contact = draft["fields"]["client"], draft["fields"]["contact"]
    assert client["id"] == h2_crm.sanlucas and client["said"] == "Institutos Alucas"
    assert client["match"] == "fuzzy" and "Lucia Molina" in client["evidence"]   # "Coincidencia aproximada" + porqué
    assert contact["id"] == lucia and contact["match"] == "exact"
    warning = next(i for i in draft["issues"] if i["field"] == "client")
    assert warning["blocking"] is False and "Lucia Molina" in warning["message"]
    assert draft["confirmable"] is True


def test_cliente_parecido_solo_no_basta_sin_contacto(run, h2_crm, lucia):
    """Sin el contacto no hay refuerzo: el parecido del ASR por sí solo no resuelve nada."""
    draft = run(call(client_name="Institutos Alucas"))
    assert draft["fields"]["client"]["id"] is None and draft["confirmable"] is False


def test_cliente_lejano_no_se_fuerza_aunque_el_contacto_sea_exacto(run, h2_crm, lucia):
    draft = run(call(client_name="Instituto Alicante", contact_name="Lucía"))
    client = draft["fields"]["client"]
    assert client["id"] is None and client["problem"] == "conflict"
    assert ("client", "conflict", True) in issues_of(draft) and draft["confirmable"] is False


def test_dos_parejas_posibles_siguen_siendo_ambiguas(run, h2_crm, lucia, factory):
    """Otro cliente igual de parecido con otra Lucía: no se elige "la mejor"."""
    otro = factory.client("Instituto Lucas")
    factory.contact(otro, "Lucia Ferrer")
    draft = run(call(client_name="Institutos Alucas", contact_name="Lucía"))
    assert draft["fields"]["client"]["id"] is None and draft["fields"]["contact"]["id"] is None
    assert draft["confirmable"] is False


def test_un_cliente_parecido_sin_esa_persona_no_estorba(run, h2_crm, lucia, factory):
    """El contacto desempata entre dos clientes parecidos: solo uno tiene a Lucía."""
    factory.client("Instituto Lucas")
    draft = run(call(client_name="Institutos Alucas", contact_name="Lucía"))
    assert draft["fields"]["client"]["id"] == h2_crm.sanlucas and draft["confirmable"] is True


def test_contacto_ambiguo_y_cliente_parecido_se_refuerzan(run, h2_crm):
    draft = run(call(client_name="Institutos Alucas", contact_name="Carlos"))
    client, contact = draft["fields"]["client"], draft["fields"]["contact"]
    assert (client["id"], contact["id"]) == (h2_crm.sanlucas, h2_crm.carlos_r)
    assert contact["match"] == "fuzzy" and "Instituto San Lucas" in contact["evidence"]
    assert draft["confirmable"] is True


def test_contacto_inexistente_no_refuerza_nada(run, h2_crm):
    draft = run(call(client_name="Institutos Alucas", contact_name="Pepe"))
    assert draft["fields"]["client"]["id"] is None and draft["confirmable"] is False


def test_cliente_dicho_exacto_no_se_cambia_por_contexto(run, h2_crm, lucia):
    draft = run(call(client_name="Rivera", contact_name="Lucía"))
    assert draft["fields"]["client"]["id"] == h2_crm.rivera
    assert ("contact", "conflict", True) in issues_of(draft) and draft["confirmable"] is False


def test_find_entities_del_chat_usa_la_misma_politica(h2_crm, lucia):
    from services.crm_tools import find_entities
    found = find_entities(h2_crm.a, client_name="Institutos Alucas", contact_name="Lucía")
    assert found["client"]["status"] == "contextual" and found["client"]["id"] == h2_crm.sanlucas
    assert found["contact"]["id"] == lucia


# =====================================================================
# E. Fechas relativas (fecha base fija)
# =====================================================================

WEDNESDAY = date(2026, 10, 7)
SATURDAY = date(2026, 10, 10)


@pytest.mark.parametrize("said, expected", [
    ("hoy", "2026-10-07"), ("esta tarde", "2026-10-07"),
    ("mañana", "2026-10-08"), ("mañana por la mañana", "2026-10-08"),
    ("pasado mañana", "2026-10-09"),
    ("el sábado", "2026-10-10"), ("sábado", "2026-10-10"), ("este sábado", "2026-10-10"),
    ("el próximo sábado", "2026-10-10"), ("el sábado que viene", "2026-10-10"),
    ("el sábado de la semana que viene", "2026-10-17"),
    ("el lunes", "2026-10-12"), ("el próximo lunes", "2026-10-12"), ("el lunes que viene", "2026-10-12"),
    ("el miércoles", "2026-10-14"), ("este miércoles", "2026-10-07"),
    ("ayer", "2026-10-06"), ("anteayer", "2026-10-05"), ("el lunes pasado", "2026-10-05"),
])
def test_fechas_relativas_desde_un_miercoles(said, expected):
    assert resolve_day(said, WEDNESDAY).isoformat() == expected


@pytest.mark.parametrize("said, expected", [
    ("el sábado", "2026-10-17"), ("este sábado", "2026-10-10"), ("el próximo sábado", "2026-10-17"),
    ("el lunes", "2026-10-12"), ("el próximo lunes", "2026-10-12"), ("pasado mañana", "2026-10-12"),
])
def test_fechas_relativas_desde_un_sabado(said, expected):
    assert resolve_day(said, SATURDAY).isoformat() == expected


@pytest.mark.parametrize("said, expected", [("el lunes", "2026-10-05"), ("el sábado", "2026-10-03"),
                                            ("este lunes", "2026-10-05"), ("ayer", "2026-10-06")])
def test_un_dia_de_la_semana_de_algo_ya_hecho_es_el_anterior(said, expected):
    assert resolve_day(said, WEDNESDAY, completed=True).isoformat() == expected


@pytest.mark.parametrize("said", ["el 15 de octubre", "mañana o el lunes", "la semana que viene", "", None])
def test_expresiones_no_reconocidas_o_ambiguas_no_se_resuelven(said):
    assert resolve_day(said, WEDNESDAY) is None


def test_el_calendario_del_interprete_usa_las_mismas_reglas():
    table = calendar_context(WEDNESDAY)
    assert table["pasado_mañana"] == "2026-10-09"
    assert table["proximo_dia_de_la_semana"]["sábado"] == resolve_day("el sábado", WEDNESDAY).isoformat()
    assert table["proximo_dia_de_la_semana"]["miércoles"] == "2026-10-14"
    assert table["ultimo_dia_de_la_semana"]["lunes"] == "2026-10-05"
    context = interpreter_module.context_message(datetime(2026, 10, 7, 9, 0))
    assert '"pasado_mañana": "2026-10-09"' in context and '"sábado": "2026-10-10"' in context


def test_la_expresion_dicha_manda_sobre_la_fecha_del_modelo(run, h2_crm):
    # H2_NOW es el jueves 2026-10-01: pasado mañana = sábado 3; el modelo se equivocó
    draft = run(call(client_name="Rivera", date="2026-10-04", date_said="pasado mañana"))
    assert draft["fields"]["date"] == "2026-10-03"

    weekday = run(call(client_name="Rivera", date=None, date_said="el próximo lunes"))
    assert weekday["fields"]["date"] == "2026-10-05"


def test_sin_expresion_reconocible_se_usa_la_fecha_del_modelo(run, h2_crm):
    draft = run(call(client_name="Rivera", date="2026-10-15", date_said="el 15 de octubre"))
    assert draft["fields"]["date"] == "2026-10-15"


def test_venta_el_lunes_es_el_lunes_pasado(run, h2_crm):
    from schemas.actions import SaleLineMention
    draft = run(interp(action_type="create_sale", client_name="Rivera", date_said="el lunes", sale_lines=[
        SaleLineMention(product_name="Luna 13", concept=None, quantity=1, amount="790", amount_is_unit_price=False)]))
    assert draft["fields"]["sale_date"] == "2026-09-28"


# =====================================================================
# F. Garantías del Action Engine (no se han debilitado)
# =====================================================================

def test_falta_un_campo_obligatorio_sigue_bloqueando(run, h2_crm, confirm, dbq):
    draft = run(call(client_name="Rivera", time=None))
    assert ("time", "missing", True) in issues_of(draft) and draft["confirmable"] is False
    assert confirm(draft).status_code == 422
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0


def test_confirmar_sigue_siendo_explicito_e_idempotente(run, h2_crm, patch, confirm, dbq, fake_embedding):
    draft = run(call(contact_name="Carlos"))
    chosen = patch(draft, {"contact_id": h2_crm.carlos_r}).json()

    assert confirm(chosen, revision=draft["revision"]).json()["code"] == "stale_revision"
    first = confirm(chosen)
    second = confirm(chosen)
    assert first.status_code == second.status_code == 200
    assert first.json()["result"] == second.json()["result"]
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 1


def test_un_borrador_confirmado_no_se_edita_ni_se_reejecuta(run, h2_crm, patch, confirm, dbq):
    draft = run(nasa())
    assert confirm(draft).status_code == 200
    closed = patch(draft, {"phone": "966000111"})
    assert closed.status_code == 409 and closed.json()["code"] == "draft_executed"
    assert confirm(draft).status_code == 200
    assert dbq.one("SELECT COUNT(*) AS n FROM clients WHERE razon_social = 'NASA Academia'")["n"] == 1


def test_un_borrador_descartado_no_se_confirma(run, h2_crm, client, user_a, confirm, dbq):
    draft = run(nasa())
    assert client.post(f"/actions/{draft['id']}/cancel", headers=user_a["headers"]).status_code == 200
    assert confirm(draft).status_code == 409
    assert dbq.one("SELECT COUNT(*) AS n FROM clients WHERE razon_social = 'NASA Academia'")["n"] == 0
