"""
ACTIVITIES (P0): create / read / update / delete y aislamiento entre usuarios,
con el formato ANTERIOR de la app Flutter (api/legacy_activity_adapter.py).
El contrato V2 (ActivityIn, estado, PATCH) está en test_writes_activities.py.

OpenAI nunca se llama: services.activities.generate_embedding se sustituye
(fake_embedding / failing_embedding); el embedding se genera después de
guardar. H.2: los errores 422/409 traen "detail" + "issues"; los duplicados
son deterministas (B2) y el tipo de actividad es obligatorio.
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
    products = sorted(listed["products"], key=lambda p: p["product_id"])
    assert [{"product_id": p["product_id"], "product_raw": p["product_raw"]} for p in products] == expected
    # H4-01: además, el nombre oficial del catálogo (lo que muestra la app)
    names = {r["id"]: r["nombre"] for r in dbq.all("SELECT id, nombre FROM products")}
    assert [p["name"] for p in products] == [names[p["product_id"]] for p in products]


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
# CREATE inválido (B3): 422 con {"detail": "..."} y sin escribir nada.
# Las validaciones de formato se hacen antes de llamar a OpenAI; una
# referencia inexistente (FK) se detecta al insertar y se deshace todo.
# ---------------------------------------------------------------------

# H.2: (overrides, campo del issue, código). El tipo de actividad es obligatorio
# (antes valía "contacto o tipo") y una referencia inexistente se nombra.
INVALID_CREATE_CASES = {
    "sin_cliente": ({"cliente_id": None}, "client", "missing"),
    "sin_tipo": ({"activity_type_id": None}, "activity_type", "missing"),
    "sin_contacto_ni_tipo": ({"contacto_id": None, "activity_type_id": None}, "activity_type", "missing"),
    "producto_sin_product_id": ({"products_detected": [{"product_raw": "Monitor", "confidence": 90}]},
                                "products", "invalid"),
    "cliente_inexistente": ({"cliente_id": 99999}, "client", "not_found"),
}


def assert_nothing_written(dbq):
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0
    assert dbq.one("SELECT COUNT(*) AS n FROM activity_products")["n"] == 0
    assert dbq.one("SELECT COUNT(*) AS n FROM activity_embeddings")["n"] == 0


@pytest.mark.parametrize("case", INVALID_CREATE_CASES)
def test_b3_create_invalido_responde_422_con_detail_y_no_escribe_nada(client_no_raise, user_a, catalog,
                                                                      fake_embedding, dbq, case):
    overrides, field, code = INVALID_CREATE_CASES[case]
    payload = create_payload(catalog, **overrides)

    response = client_no_raise.post("/activities", json=payload, headers=user_a["headers"])

    assert response.status_code == 422
    body = response.json()
    assert isinstance(body["detail"], str) and body["detail"]
    assert [(i["field"], i["code"], i["blocking"]) for i in body["issues"]] == [(field, code, True)]
    assert_nothing_written(dbq)


@pytest.mark.parametrize("case", ["sin_cliente", "sin_contacto_ni_tipo", "producto_sin_product_id"])
def test_create_invalido_no_llama_a_openai(client, user_a, catalog, fake_embedding, case):
    payload = create_payload(catalog, **INVALID_CREATE_CASES[case][0])  # el embedding va tras guardar

    assert client.post("/activities", json=payload, headers=user_a["headers"]).status_code == 422
    assert fake_embedding.calls == []


@pytest.mark.parametrize("field", ["contacto_id", "activity_type_id"])
def test_create_referencia_inexistente_422_y_rollback_completo(client, user_a, catalog, fake_embedding,
                                                               dbq, field):
    # El INSERT de la actividad falla por FK: no queda nada a medias
    response = client.post("/activities", json=create_payload(catalog, **{field: 99999}),
                           headers=user_a["headers"])

    assert response.status_code == 422
    assert_nothing_written(dbq)


def test_create_producto_inexistente_422_y_deshace_la_actividad(client, user_a, catalog, fake_embedding, dbq):
    # La actividad se inserta antes que el producto: la transacción debe deshacerla
    payload = create_payload(catalog, products_detected=[
        {"product_id": catalog["monitor"], "product_raw": "Monitor Test 24", "confidence": 95},
        {"product_id": 99999, "product_raw": "No existe", "confidence": 90},
    ])

    response = client.post("/activities", json=payload, headers=user_a["headers"])

    assert response.status_code == 422
    assert [(i["field"], i["code"]) for i in response.json()["issues"]] == [("products[1]", "not_found")]
    assert_nothing_written(dbq)


def test_create_duplicada_409_sin_escribir(client, user_a, catalog, fake_embedding, dbq):
    """B2 (H.2): duplicado exacto determinista (mismo cliente, contacto, tipo y minuto), sin embeddings."""
    first = client.post("/activities", json=create_payload(catalog), headers=user_a["headers"])
    assert first.status_code == 200
    calls_before = len(fake_embedding.calls)

    response = client.post("/activities", json=create_payload(catalog), headers=user_a["headers"])

    assert response.status_code == 409
    body = response.json()
    assert body["code"] == "duplicate_activity" and body["existing_id"] == first.json()["activity_id"]
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 1
    assert len(fake_embedding.calls) == calls_before        # no se generó nada para el duplicado


def test_create_producto_sin_product_raw_ni_confidence_se_guarda(client, user_a, catalog, fake_embedding, dbq):
    payload = create_payload(catalog, products_detected=[{"product_id": catalog["licencia"]}])

    response = client.post("/activities", json=payload, headers=user_a["headers"])

    assert response.status_code == 200
    assert dbq.activity_products(response.json()["activity_id"]) == [
        {"product_id": catalog["licencia"], "product_raw": None},
    ]


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


def test_update_rechaza_productos_sin_id(client, user_a, catalog, a_activity, fake_embedding, dbq):
    """H.2: un producto sin id ya no se descarta en silencio (antes se ignoraba): 422 y nada cambia."""
    before = activity_state(dbq, a_activity)
    payload = update_payload(catalog, [
        {"name": "Producto sin id"},
        {"id": catalog["portatil"], "name": "Portátil Test 14"},
    ])

    response = client.put(f"/activities/{a_activity}", json=payload, headers=user_a["headers"])

    assert response.status_code == 422
    assert response.json()["issues"][0]["field"] == "products"
    assert activity_state(dbq, a_activity) == before


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


# ---------------------------------------------------------------------
# UPDATE incompleto (B7): PUT es una sustitución completa. Si falta un campo
# no se pone a NULL: 422 y la actividad queda intacta. El comentario es
# opcional (si no se envía se conserva).
# ---------------------------------------------------------------------

@pytest.mark.parametrize("missing", ["fecha", "client_id", "contact_id", "activity_type_id", "products"])
def test_b7_update_sin_un_campo_obligatorio_422_sin_cambios(client, user_a, catalog, a_activity,
                                                            fake_embedding, dbq, missing):
    before = activity_state(dbq, a_activity)
    payload = update_payload(catalog, [])
    del payload[missing]

    response = client.put(f"/activities/{a_activity}", json=payload, headers=user_a["headers"])

    assert response.status_code == 422
    assert response.json()["detail"] == f"Faltan campos obligatorios: {missing}"
    assert response.json()["issues"][0]["code"] == "missing"
    assert activity_state(dbq, a_activity) == before
    assert fake_embedding.calls == []


@pytest.mark.parametrize("field,value,detail", [
    ("fecha", None, "Fecha obligatoria"),
    ("fecha", "", "Fecha obligatoria"),
    ("client_id", None, "Cliente obligatorio"),
    ("products", None, "products debe ser una lista de productos"),
    ("products", ["no-es-un-objeto"], "products debe ser una lista de productos"),
])
def test_b7_update_con_valor_obligatorio_nulo_o_invalido_422(client, user_a, catalog, a_activity,
                                                             fake_embedding, dbq, field, value, detail):
    before = activity_state(dbq, a_activity)
    payload = {**update_payload(catalog, []), field: value}

    response = client.put(f"/activities/{a_activity}", json=payload, headers=user_a["headers"])

    assert response.status_code == 422
    assert response.json()["detail"] == detail
    assert activity_state(dbq, a_activity) == before


def test_b7_update_contacto_null_se_acepta_y_tipo_null_no(client, user_a, catalog, a_activity,
                                                          fake_embedding, dbq):
    """H.2: el contacto es opcional; el tipo de actividad es obligatorio (antes se aceptaba null)."""
    no_contact = {**update_payload(catalog, []), "contact_id": None}
    assert client.put(f"/activities/{a_activity}", json=no_contact,
                      headers=user_a["headers"]).json() == {"success": True}
    assert dbq.activity(a_activity)["contact_id"] is None

    before = activity_state(dbq, a_activity)
    no_type = {**no_contact, "activity_type_id": None}
    response = client.put(f"/activities/{a_activity}", json=no_type, headers=user_a["headers"])

    assert response.status_code == 422
    assert response.json()["detail"] == "Tipo de actividad obligatorio"
    assert response.json()["issues"][0] == {**response.json()["issues"][0], "field": "activity_type",
                                             "code": "missing"}
    assert activity_state(dbq, a_activity) == before


def test_b7_update_incompleto_de_otro_usuario_es_404_no_422(client, user_b, catalog, a_activity,
                                                            fake_embedding, dbq):
    """La propiedad se comprueba antes que el payload: B no averigua nada."""
    before = activity_state(dbq, a_activity)

    response = client.put(f"/activities/{a_activity}", json={"fecha": "2030-01-01"},
                          headers=user_b["headers"])

    assert response.status_code == 404
    assert response.json() == {"detail": "Actividad no encontrada"}
    assert activity_state(dbq, a_activity) == before


def test_update_referencia_inexistente_422_sin_cambios(client, user_a, catalog, a_activity,
                                                       fake_embedding, dbq):
    before = activity_state(dbq, a_activity)
    payload = update_payload(catalog, [{"id": 99999, "name": "No existe"}])

    response = client.put(f"/activities/{a_activity}", json=payload, headers=user_a["headers"])

    assert response.status_code == 422
    assert [(i["field"], i["code"]) for i in response.json()["issues"]] == [("products[0]", "not_found")]
    assert activity_state(dbq, a_activity) == before


# ---------------------------------------------------------------------
# B10: ninguna conexión queda abierta, tampoco en los caminos de error
# ---------------------------------------------------------------------

class _TrackedConnection:
    """Proxy de la conexión real que registra si se ha llamado a close()."""

    def __init__(self, conn):
        self._conn = conn
        self.closed = False

    def close(self):
        self.closed = True
        self._conn.close()

    def __getattr__(self, name):
        return getattr(self._conn, name)


@pytest.fixture
def opened_connections(monkeypatch):
    import db
    opened = []
    real_get_connection = db.get_connection

    def tracking():
        conn = _TrackedConnection(real_get_connection())
        opened.append(conn)
        return conn

    monkeypatch.setattr(db, "get_connection", tracking)
    return opened


def assert_all_closed(connections):
    assert connections
    assert all(conn.closed for conn in connections)


@pytest.mark.parametrize("scenario", ["create_ok", "create_fk", "update_ok", "update_fk", "update_incompleto",
                                      "delete_ok", "delete_404", "list"])
def test_b10_las_conexiones_se_cierran_siempre(client, user_a, catalog, a_activity, fake_embedding,
                                               opened_connections, scenario):
    headers = user_a["headers"]
    requests = {
        # Otra hora: la misma que a_activity sería un duplicado exacto (409, H.2)
        "create_ok": lambda: client.post("/activities", json=create_payload(
            catalog, fecha_detectada="2026-10-01T12:00:00"), headers=headers),
        "create_fk": lambda: client.post("/activities", json=create_payload(catalog, cliente_id=99999),
                                         headers=headers),
        "update_ok": lambda: client.put(f"/activities/{a_activity}", json=update_payload(catalog, []),
                                        headers=headers),
        "update_fk": lambda: client.put(f"/activities/{a_activity}",
                                        json={**update_payload(catalog, []), "client_id": 99999},
                                        headers=headers),
        "update_incompleto": lambda: client.put(f"/activities/{a_activity}", json={}, headers=headers),
        "delete_ok": lambda: client.delete(f"/activities/{a_activity}", headers=headers),
        "delete_404": lambda: client.delete("/activities/99999", headers=headers),
        "list": lambda: client.get("/activities", headers=headers),
    }

    response = requests[scenario]()

    assert response.status_code in (200, 404, 422)
    assert_all_closed(opened_connections)


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
