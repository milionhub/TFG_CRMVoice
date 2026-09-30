"""
ACTIVITIES (P0): create / read / update / delete y aislamiento entre usuarios.

OpenAI nunca se llama: services.activities.generate_embedding se sustituye (fake_embedding /
failing_embedding) y la comprobación de duplicados (B2) se desactiva en los
tests de creación para que no dependan de ella. B2 queda pendiente (D.x).
"""
import json

import pytest


# ---------------------------------------------------------------------
# Datos comunes
# ---------------------------------------------------------------------

@pytest.fixture
def catalog(factory):
    """Catálogo mínimo compartido (los catálogos no tienen propietario)."""
    nebula = factory.client("Nebula Test S.L.", alias="Nebula")
    orion = factory.client("Orion Test S.L.", alias="Orion")
    return {
        "nebula": nebula,
        "orion": orion,
        "nora": factory.contact(nebula, "Nora Test"),
        "alma": factory.contact(orion, "Alma Test"),
        "monitor": factory.product("Monitor Test 24", 189.0, aliases=["monitor test"]),
        "portatil": factory.product("Portátil Test 14", 849.0),
        "licencia": factory.product("Licencia Test", 120.0),
        "reunion": factory.activity_type_id("Concertar reunión"),
        "llamada": factory.activity_type_id("Realizar llamada de seguimiento"),
    }


def create_payload(catalog, **overrides):
    """Mismo formato que envía new_activity_screen.dart al guardar."""
    payload = {
        "cliente_id": catalog["nebula"],
        "contacto_id": catalog["nora"],
        "activity_type_id": catalog["reunion"],
        "fecha_detectada": "2026-10-01T10:00:00",
        "texto": "Reunión con Nora de Nebula para el monitor",
        "products_detected": [
            {"product_id": catalog["monitor"], "product_raw": "Monitor Test 24", "confidence": 95},
        ],
        "cliente_detectado": "Nebula",
        "contacto_detectado": "Nora",
        "accion_detectada": "Concertar reunión",
        "resolution_status": "high",
        "overall_confidence": 90,
    }
    payload.update(overrides)
    return payload


def activity_ids(client, user, **params):
    response = client.get("/activities", headers=user["headers"], params=params)
    assert response.status_code == 200
    return sorted(a["id"] for a in response.json()["activities"])


# =====================================================================
# CREATE
# =====================================================================

def test_create_guarda_la_actividad_y_se_recupera_con_get(client, user_a, catalog, fake_embedding, dbq):
    response = client.post("/activities", json=create_payload(catalog), headers=user_a["headers"])

    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    activity_id = body["activity_id"]

    listed = client.get("/activities", headers=user_a["headers"]).json()
    assert listed["count"] == 1
    activity = listed["activities"][0]
    assert activity["id"] == activity_id
    assert activity["fecha"] == "2026-10-01T10:00:00"
    assert activity["client_id"] == catalog["nebula"]
    assert activity["contact_id"] == catalog["nora"]
    assert activity["activity_type_id"] == catalog["reunion"]
    assert activity["cliente"] == "Nebula Test S.L."
    assert activity["contacto"] == "Nora Test"
    assert activity["accion"] == "Concertar reunión"
    assert activity["comentario"] == "Reunión con Nora de Nebula para el monitor"
    assert activity["resolution_status"] == "high"

    stored = dbq.activity(activity_id)
    assert stored["salesperson_id"] == user_a["id"]
    assert stored["transcripcion"] == "Reunión con Nora de Nebula para el monitor"
    assert stored["cliente_raw"] == "Nebula"
    assert stored["resolution_confidence"] == 90


def test_create_con_varios_productos_guarda_product_id_correcto(client, user_a, catalog, fake_embedding, dbq):
    payload = create_payload(catalog, products_detected=[
        {"product_id": catalog["monitor"], "product_raw": "monitor test", "confidence": 90},
        {"product_id": catalog["licencia"], "product_raw": "Licencia Test", "confidence": 100},
    ])

    activity_id = client.post("/activities", json=payload, headers=user_a["headers"]).json()["activity_id"]

    expected = sorted([
        {"product_id": catalog["monitor"], "product_raw": "monitor test"},
        {"product_id": catalog["licencia"], "product_raw": "Licencia Test"},
    ], key=lambda p: p["product_id"])
    assert dbq.activity_products(activity_id) == expected

    listed = client.get("/activities", headers=user_a["headers"]).json()["activities"][0]
    assert sorted(listed["products"], key=lambda p: p["product_id"]) == expected


def test_create_sin_productos(client, user_a, catalog, fake_embedding, dbq):
    payload = create_payload(catalog, products_detected=[])

    activity_id = client.post("/activities", json=payload, headers=user_a["headers"]).json()["activity_id"]

    assert dbq.activity_products(activity_id) == []


def test_create_guarda_el_embedding_generado_en_su_actividad(client, user_a, catalog, factory,
                                                             fake_embedding, dbq):
    # Actividad previa con su propio embedding (distinto del que genera el fake)
    previous = factory.activity(user_a["id"], catalog["orion"], embedding=[9.0, 9.0, 9.0])
    previous_embeddings = dbq.embeddings(previous)

    activity_id = client.post("/activities", json=create_payload(catalog),
                              headers=user_a["headers"]).json()["activity_id"]

    assert activity_id != previous
    assert len(fake_embedding.calls) == 1
    assert "Reunión con Nora de Nebula para el monitor" in fake_embedding.calls[0]
    # El nuevo embedding está asociado exactamente a la actividad creada...
    embeddings = dbq.embeddings(activity_id)
    assert len(embeddings) == 1
    assert json.loads(embeddings[0]["embedding_vector"]) == fake_embedding.vector
    # ...y el de la actividad previa sigue intacto
    assert dbq.embeddings(previous) == previous_embeddings
    assert dbq.one("SELECT COUNT(*) AS n FROM activity_embeddings")["n"] == 2


def test_create_si_falla_el_embedding_la_actividad_se_guarda_igual(client, user_a, catalog,
                                                                   failing_embedding, dbq):
    response = client.post("/activities", json=create_payload(catalog), headers=user_a["headers"])

    assert response.status_code == 200
    assert response.json()["success"] is True
    activity_id = response.json()["activity_id"]
    assert len(failing_embedding.calls) == 1
    assert dbq.activity(activity_id) is not None
    assert len(dbq.activity_products(activity_id)) == 1
    assert dbq.embeddings(activity_id) == []


def test_create_el_propietario_sale_del_token_no_del_body(client, user_a, user_b, catalog, fake_embedding, dbq):
    payload = create_payload(catalog, salesperson_id=user_b["id"])

    activity_id = client.post("/activities", json=payload, headers=user_a["headers"]).json()["activity_id"]

    assert dbq.activity(activity_id)["salesperson_id"] == user_a["id"]
    assert activity_ids(client, user_b) == []


# ---------------------------------------------------------------------
# CREATE: contratos dudosos (B3). NO se corrigen en este bloque.
#
# Contrato actual:
#   - sin cliente, o sin contacto ni tipo  -> 200 {"error": "..."}
#   - producto sin product_id              -> 500 (KeyError)
#   - cliente_id inexistente               -> 500 (IntegrityError de la FK)
# Contrato propuesto para una fase posterior: 422 (o 400) con un detail
# claro, sin 500 y sin escribir nada. Los xfail(strict) fallarán en cuanto
# se corrija B3, obligando a revisar el test.
# Lo que SÍ se protege ya: una creación inválida no deja nada escrito.
# ---------------------------------------------------------------------

INVALID_CREATE_CASES = {
    "sin_cliente": {"cliente_id": None},
    "sin_contacto_ni_tipo": {"contacto_id": None, "activity_type_id": None},
    "producto_sin_product_id": {"products_detected": [{"product_raw": "Monitor", "confidence": 90}]},
    "cliente_inexistente": {"cliente_id": 99999},
}


@pytest.mark.parametrize("case", INVALID_CREATE_CASES)
def test_create_invalido_no_escribe_nada(client_no_raise, user_a, catalog, fake_embedding, dbq, case):
    payload = create_payload(catalog, **INVALID_CREATE_CASES[case])

    response = client_no_raise.post("/activities", json=payload, headers=user_a["headers"])

    # Hoy puede ser 200 + {"error"} o un 500 en texto plano (B3)
    if response.status_code == 200:
        assert response.json().get("success") is not True
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0
    assert dbq.one("SELECT COUNT(*) AS n FROM activity_products")["n"] == 0
    assert dbq.one("SELECT COUNT(*) AS n FROM activity_embeddings")["n"] == 0


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="B3: hoy responde 200 + {'error': ...} o 500; contrato deseado 4xx")
@pytest.mark.parametrize("case", INVALID_CREATE_CASES)
def test_b3_create_invalido_deberia_responder_4xx(client_no_raise, user_a, catalog, fake_embedding, case):
    payload = create_payload(catalog, **INVALID_CREATE_CASES[case])

    response = client_no_raise.post("/activities", json=payload, headers=user_a["headers"])

    assert 400 <= response.status_code < 500


# =====================================================================
# READ: cada usuario solo ve sus actividades
# =====================================================================

def test_get_cada_usuario_solo_ve_sus_actividades(client, user_a, user_b, catalog, factory):
    a1 = factory.activity(user_a["id"], catalog["nebula"], comentario="A1")
    a2 = factory.activity(user_a["id"], catalog["orion"], comentario="A2")
    b1 = factory.activity(user_b["id"], catalog["nebula"], comentario="B1")

    assert activity_ids(client, user_a) == sorted([a1, a2])
    assert activity_ids(client, user_b) == [b1]

    comentarios_a = {a["comentario"] for a in client.get("/activities", headers=user_a["headers"]).json()["activities"]}
    assert comentarios_a == {"A1", "A2"}


def test_get_filtro_por_cliente_no_mezcla_usuarios(client, user_a, user_b, catalog, factory):
    a1 = factory.activity(user_a["id"], catalog["nebula"])
    factory.activity(user_a["id"], catalog["orion"])
    factory.activity(user_b["id"], catalog["nebula"])

    assert activity_ids(client, user_a, client_id=catalog["nebula"]) == [a1]


def test_get_usuario_sin_actividades(client, user_a, user_b, catalog, factory):
    factory.activity(user_b["id"], catalog["nebula"])

    response = client.get("/activities", headers=user_a["headers"])

    assert response.json() == {"count": 0, "activities": []}


def test_get_cada_actividad_lista_solo_sus_productos(client, user_a, user_b, catalog, factory):
    # A: dos actividades con productos distintos; B: otra con un producto que A no tiene
    a1 = factory.activity(user_a["id"], catalog["nebula"], products=[(catalog["monitor"], "Monitor Test 24")])
    a2 = factory.activity(user_a["id"], catalog["orion"], products=[(catalog["portatil"], "Portátil Test 14")])
    b1 = factory.activity(user_b["id"], catalog["nebula"], products=[(catalog["licencia"], "Licencia Test")])

    def products_by_activity(user):
        activities = client.get("/activities", headers=user["headers"]).json()["activities"]
        return {a["id"]: [p["product_id"] for p in a["products"]] for a in activities}

    assert products_by_activity(user_a) == {a1: [catalog["monitor"]], a2: [catalog["portatil"]]}
    assert products_by_activity(user_b) == {b1: [catalog["licencia"]]}
    # Ningún producto de B aparece asociado a actividades de A
    listed_a = [p for ids in products_by_activity(user_a).values() for p in ids]
    assert catalog["licencia"] not in listed_a


# =====================================================================
# UPDATE
# =====================================================================

@pytest.fixture
def a_activity(factory, user_a, catalog):
    """Actividad de A con un producto y embedding."""
    return factory.activity(
        user_a["id"], catalog["nebula"],
        contact_id=catalog["nora"], activity_type_id=catalog["reunion"],
        comentario="Comentario original de A",
        products=[(catalog["monitor"], "Monitor Test 24")],
        embedding=[1.0, 0.0, 0.0],
    )


def update_payload(catalog, products):
    """Mismo formato que envía calendar_screen.dart (sin 'comentario')."""
    return {
        "fecha": "2026-11-15T09:30:00",
        "client_id": catalog["orion"],
        "contact_id": catalog["alma"],
        "activity_type_id": catalog["llamada"],
        "products": products,
    }


def test_update_propietario_modifica_campos_y_reemplaza_productos(client, user_a, catalog,
                                                                  a_activity, fake_embedding, dbq):
    payload = update_payload(catalog, [
        {"id": catalog["portatil"], "name": "Portátil Test 14"},
        {"id": catalog["licencia"], "name": "Licencia Test"},
    ])

    response = client.put(f"/activities/{a_activity}", json=payload, headers=user_a["headers"])

    assert response.status_code == 200
    assert response.json() == {"success": True}
    stored = dbq.activity(a_activity)
    assert stored["datetime_iso"] == "2026-11-15T09:30:00"
    assert stored["client_id"] == catalog["orion"]
    assert stored["contact_id"] == catalog["alma"]
    assert stored["activity_type_id"] == catalog["llamada"]
    assert stored["salesperson_id"] == user_a["id"]
    # El monitor original se ha sustituido
    assert dbq.activity_products(a_activity) == sorted([
        {"product_id": catalog["portatil"], "product_raw": "Portátil Test 14"},
        {"product_id": catalog["licencia"], "product_raw": "Licencia Test"},
    ], key=lambda p: p["product_id"])


def activity_state(dbq, activity_id):
    """Estado completo de una actividad: fila, productos y embedding."""
    return {
        "activity": dbq.activity(activity_id),
        "products": dbq.activity_products(activity_id),
        "embeddings": dbq.embeddings(activity_id),
    }


@pytest.mark.parametrize("products", [
    pytest.param([{"id": "portatil", "name": "Portátil Test 14"}], id="reemplazo"),
    pytest.param([], id="lista_vacia"),
])
def test_update_no_toca_otras_actividades_de_a_ni_de_b(client, user_a, user_b, catalog, factory,
                                                       a_activity, fake_embedding, dbq, products):
    # Actividades testigo, con productos y embedding propios
    other_a = factory.activity(user_a["id"], catalog["orion"], comentario="Otra de A",
                               products=[(catalog["licencia"], "Licencia Test")], embedding=[0.0, 1.0, 0.0])
    b_activity = factory.activity(user_b["id"], catalog["nebula"], comentario="De B",
                                  products=[(catalog["monitor"], "Monitor Test 24")], embedding=[0.0, 0.0, 1.0])
    before = {aid: activity_state(dbq, aid) for aid in (other_a, b_activity)}
    assert all(state["products"] and state["embeddings"] for state in before.values())

    payload = update_payload(catalog, [{**p, "id": catalog[p["id"]]} for p in products])
    response = client.put(f"/activities/{a_activity}", json=payload, headers=user_a["headers"])

    assert response.json() == {"success": True}
    assert dbq.activity(a_activity)["datetime_iso"] == "2026-11-15T09:30:00"  # el PUT sí se aplicó
    for aid, state in before.items():
        assert activity_state(dbq, aid) == state


def test_update_acepta_formato_product_id_product_raw(client, user_a, catalog, a_activity,
                                                      fake_embedding, dbq):
    # Formato que devuelve GET /activities (lo reutiliza la edición)
    payload = update_payload(catalog, [{"product_id": catalog["licencia"], "product_raw": "Licencia Test"}])

    response = client.put(f"/activities/{a_activity}", json=payload, headers=user_a["headers"])

    assert response.json() == {"success": True}
    assert dbq.activity_products(a_activity) == [
        {"product_id": catalog["licencia"], "product_raw": "Licencia Test"},
    ]


def test_update_ignora_productos_sin_id(client, user_a, catalog, a_activity, fake_embedding, dbq):
    payload = update_payload(catalog, [
        {"name": "Producto sin id"},
        {"product_raw": "Otro sin id"},
        {"id": catalog["portatil"], "name": "Portátil Test 14"},
    ])

    response = client.put(f"/activities/{a_activity}", json=payload, headers=user_a["headers"])

    assert response.json() == {"success": True}
    assert dbq.activity_products(a_activity) == [
        {"product_id": catalog["portatil"], "product_raw": "Portátil Test 14"},
    ]


def test_update_lista_vacia_elimina_los_productos(client, user_a, catalog, a_activity, fake_embedding, dbq):
    response = client.put(f"/activities/{a_activity}", json=update_payload(catalog, []),
                          headers=user_a["headers"])

    assert response.json() == {"success": True}
    assert dbq.activity_products(a_activity) == []


def test_update_sin_comentario_conserva_comentario_y_embedding(client, user_a, catalog, a_activity,
                                                               fake_embedding, dbq):
    embedding_before = dbq.embeddings(a_activity)

    response = client.put(f"/activities/{a_activity}", json=update_payload(catalog, []),
                          headers=user_a["headers"])

    assert response.json() == {"success": True}
    assert dbq.activity(a_activity)["comentario"] == "Comentario original de A"
    assert fake_embedding.calls == []  # no se regenera
    assert dbq.embeddings(a_activity) == embedding_before


def test_update_actividad_inexistente_404(client, user_a, catalog, fake_embedding):
    response = client.put("/activities/99999", json=update_payload(catalog, []), headers=user_a["headers"])

    assert response.status_code == 404


# =====================================================================
# DELETE
# =====================================================================

def test_delete_propietario_elimina_actividad_productos_y_embedding(client, user_a, user_b, catalog,
                                                                   factory, a_activity, dbq):
    other_a = factory.activity(user_a["id"], catalog["orion"], products=[(catalog["licencia"], "Licencia")],
                               embedding=[0.0, 1.0, 0.0])
    b_activity = factory.activity(user_b["id"], catalog["nebula"], products=[(catalog["monitor"], "Monitor")],
                                  embedding=[0.0, 0.0, 1.0])

    response = client.delete(f"/activities/{a_activity}", headers=user_a["headers"])

    assert response.status_code == 200
    assert response.json() == {"success": True}
    assert dbq.activity(a_activity) is None
    assert dbq.activity_products(a_activity) == []
    assert dbq.embeddings(a_activity) == []
    # El resto no se toca
    for untouched in (other_a, b_activity):
        assert dbq.activity(untouched) is not None
        assert len(dbq.activity_products(untouched)) == 1
        assert len(dbq.embeddings(untouched)) == 1


def test_delete_actividad_inexistente_404(client, user_a):
    response = client.delete("/activities/99999", headers=user_a["headers"])

    assert response.status_code == 404


def test_delete_dos_veces_la_segunda_es_404(client, user_a, a_activity):
    assert client.delete(f"/activities/{a_activity}", headers=user_a["headers"]).status_code == 200
    assert client.delete(f"/activities/{a_activity}", headers=user_a["headers"]).status_code == 404
