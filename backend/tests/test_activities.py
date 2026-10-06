"""
ACTIVITIES (P0): create / read / update / delete y aislamiento entre usuarios
por HTTP, con el cuerpo V2 (ActivityIn), el único que acepta la API desde
H.5.2 (el formato anterior de la app y su adaptador se retiraron). Las reglas
de negocio V2 (estado, duplicados, PATCH) están en test_writes_activities.py.

OpenAI nunca se llama: services.activities.generate_embedding se sustituye
(fake_embedding / failing_embedding); el embedding se genera después de
guardar. Los errores 422/409 traen "detail" + "issues".
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


def v2_body(catalog, **overrides):
    """Cuerpo V2 (ActivityIn) como el que envía el formulario de actividad de la app."""
    data = {
        "client_id": catalog["nebula"],
        "contact_id": catalog["nora"],
        "activity_type_id": catalog["reunion"],
        "datetime": "2026-10-01T10:00",
        "status": "pending",
        "product_ids": [catalog["monitor"]],
        "comment": "Reunión con Nora de Nebula para el monitor",
    }
    data.update(overrides)
    return data


def activity_ids(client, user, **params):
    response = client.get("/activities", headers=user["headers"], params=params)
    assert response.status_code == 200
    return sorted(a["id"] for a in response.json()["activities"])


# =====================================================================
# CREATE (V2)
# =====================================================================

def test_create_v2_guarda_la_actividad_y_el_listado_muestra_el_nombre_oficial(client, user_a, catalog,
                                                                             fake_embedding, dbq):
    response = client.post("/activities", json=v2_body(catalog, product_ids=[catalog["monitor"], catalog["licencia"]]),
                           headers=user_a["headers"])

    assert response.status_code == 201, response.json()
    activity_id = response.json()["id"]
    stored = dbq.activity(activity_id)
    assert (stored["salesperson_id"], stored["client_id"], stored["status"]) == (user_a["id"], catalog["nebula"],
                                                                               "pending")
    listed = client.get("/activities", headers=user_a["headers"]).json()["activities"][0]
    assert listed["id"] == activity_id and listed["fecha"] == "2026-10-01T10:00:00"
    products = sorted(listed["products"], key=lambda p: p["product_id"])
    names = {r["id"]: r["nombre"] for r in dbq.all("SELECT id, nombre FROM products")}
    # El formulario no aporta texto dicho: product_raw NULL; la app muestra el nombre oficial (H4-01)
    assert [(p["product_id"], p["name"], p["product_raw"]) for p in products] == [
        (pid, names[pid], None) for pid in sorted([catalog["monitor"], catalog["licencia"]])]


def test_create_guarda_el_embedding_generado_en_su_actividad(client, user_a, catalog, factory,
                                                             fake_embedding, dbq):
    previous = factory.activity(user_a["id"], catalog["orion"], embedding=[9.0, 9.0, 9.0])
    previous_embeddings = dbq.embeddings(previous)

    activity_id = client.post("/activities", json=v2_body(catalog), headers=user_a["headers"]).json()["id"]

    assert activity_id != previous
    assert len(fake_embedding.calls) == 1
    assert "Reunión con Nora de Nebula para el monitor" in fake_embedding.calls[0]
    embeddings = dbq.embeddings(activity_id)
    assert len(embeddings) == 1
    assert json.loads(embeddings[0]["embedding_vector"]) == fake_embedding.vector
    assert dbq.embeddings(previous) == previous_embeddings


def test_create_si_falla_el_embedding_la_actividad_se_guarda_igual(client, user_a, catalog,
                                                                   failing_embedding, dbq):
    response = client.post("/activities", json=v2_body(catalog), headers=user_a["headers"])

    assert response.status_code == 201
    activity_id = response.json()["id"]
    assert len(failing_embedding.calls) == 1
    assert dbq.activity(activity_id) is not None
    assert len(dbq.activity_products(activity_id)) == 1
    assert dbq.embeddings(activity_id) == []


def test_create_el_propietario_sale_del_token_y_no_se_admite_en_el_cuerpo(client, user_a, user_b, catalog,
                                                                         fake_embedding, dbq):
    response = client.post("/activities", json=v2_body(catalog, salesperson_id=user_b["id"]),
                           headers=user_a["headers"])

    assert response.status_code == 422                       # campo no permitido: nadie elige el propietario
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0


LEGACY_CREATE = {  # lo que enviaba la antigua NewActivityScreen (Voice V1)
    "cliente_id": 1, "contacto_id": 1, "fecha_detectada": "2026-10-01T10:00:00", "texto": "Reunión",
    "products_detected": [], "cliente_detectado": "Nebula", "accion_detectada": "Concertar reunión",
    "resolution_status": "high", "overall_confidence": 90,
}


def test_un_cuerpo_del_formato_anterior_ya_no_se_procesa(client, user_a, catalog, fake_embedding, dbq):
    response = client.post("/activities", json=LEGACY_CREATE, headers=user_a["headers"])

    assert response.status_code == 422
    assert "success" not in response.json() and response.json()["issues"]
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0
    assert fake_embedding.calls == []


def test_un_put_del_formato_anterior_ya_no_se_procesa(client, user_a, catalog, a_activity, fake_embedding, dbq):
    before = dbq.activity(a_activity)
    legacy_update = {"fecha": "2026-11-15T09:30:00", "client_id": catalog["orion"], "contact_id": catalog["alma"],
                     "activity_type_id": catalog["llamada"], "products": []}

    response = client.put(f"/activities/{a_activity}", json=legacy_update, headers=user_a["headers"])

    assert response.status_code == 422
    assert dbq.activity(a_activity) == before


@pytest.mark.parametrize("overrides,field", [
    ({"client_id": 99999}, "client"),
    ({"contact_id": 99999}, "contact"),
    ({"activity_type_id": 99999}, "activity_type"),
    ({"product_ids": [99999]}, "products[0]"),
])
def test_create_referencia_inexistente_422_sin_escribir(client, user_a, catalog, fake_embedding, dbq,
                                                         overrides, field):
    response = client.post("/activities", json=v2_body(catalog, **overrides), headers=user_a["headers"])

    assert response.status_code == 422
    assert field in [i["field"] for i in response.json()["issues"]]
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0
    assert fake_embedding.calls == []


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
# UPDATE (V2)
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


def update_body(catalog, **overrides):
    changes = {"client_id": catalog["orion"], "contact_id": catalog["alma"], "activity_type_id": catalog["llamada"],
               "datetime": "2026-11-15T09:30", "product_ids": [], "comment": "Comentario original de A"}
    return v2_body(catalog, **{**changes, **overrides})


def test_update_propietario_modifica_campos_y_reemplaza_productos(client, user_a, catalog, a_activity,
                                                                 fake_embedding, dbq):
    response = client.put(f"/activities/{a_activity}", json=update_body(catalog, product_ids=[catalog["portatil"]]),
                          headers=user_a["headers"])

    assert response.status_code == 200, response.json()
    stored = dbq.activity(a_activity)
    assert (stored["client_id"], stored["contact_id"], stored["datetime_iso"]) == (
        catalog["orion"], catalog["alma"], "2026-11-15T09:30:00")
    assert [p["product_id"] for p in dbq.activity_products(a_activity)] == [catalog["portatil"]]


def test_update_no_toca_otras_actividades_de_a_ni_de_b(client, user_a, user_b, catalog, factory, a_activity,
                                                        fake_embedding, dbq):
    other_a = factory.activity(user_a["id"], catalog["nebula"], datetime_iso="2026-10-05T10:00:00")
    other_b = factory.activity(user_b["id"], catalog["nebula"], datetime_iso="2026-10-05T10:00:00")
    before = [dbq.activity(other_a), dbq.activity(other_b)]

    assert client.put(f"/activities/{a_activity}", json=update_body(catalog),
                      headers=user_a["headers"]).status_code == 200
    assert [dbq.activity(other_a), dbq.activity(other_b)] == before


def test_update_sin_cambiar_el_comentario_conserva_el_embedding(client, user_a, catalog, a_activity,
                                                               fake_embedding, dbq):
    embedding_before = dbq.embeddings(a_activity)

    response = client.put(f"/activities/{a_activity}", json=update_body(catalog), headers=user_a["headers"])

    assert response.status_code == 200
    assert fake_embedding.calls == []                       # no se regenera
    assert dbq.embeddings(a_activity) == embedding_before


def test_update_con_otro_comentario_regenera_el_embedding(client, user_a, catalog, a_activity, fake_embedding, dbq):
    response = client.put(f"/activities/{a_activity}", json=update_body(catalog, comment="Nuevo comentario"),
                          headers=user_a["headers"])

    assert response.status_code == 200
    assert len(fake_embedding.calls) == 1 and "Nuevo comentario" in fake_embedding.calls[0]
    assert json.loads(dbq.embeddings(a_activity)[0]["embedding_vector"]) == fake_embedding.vector


def test_update_actividad_inexistente_o_de_otro_404(client, user_a, user_b, catalog, a_activity, fake_embedding):
    assert client.put("/activities/99999", json=update_body(catalog), headers=user_a["headers"]).status_code == 404
    assert client.put(f"/activities/{a_activity}", json=update_body(catalog),
                      headers=user_b["headers"]).status_code == 404


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
        # Otra hora: la misma que a_activity sería un duplicado exacto (409)
        "create_ok": lambda: client.post("/activities", json=v2_body(catalog, datetime="2026-10-01T12:00"),
                                         headers=headers),
        "create_fk": lambda: client.post("/activities", json=v2_body(catalog, client_id=99999), headers=headers),
        "update_ok": lambda: client.put(f"/activities/{a_activity}", json=update_body(catalog), headers=headers),
        "update_fk": lambda: client.put(f"/activities/{a_activity}", json=update_body(catalog, client_id=99999),
                                        headers=headers),
        "update_incompleto": lambda: client.put(f"/activities/{a_activity}", json={}, headers=headers),
        "delete_ok": lambda: client.delete(f"/activities/{a_activity}", headers=headers),
        "delete_404": lambda: client.delete("/activities/99999", headers=headers),
        "list": lambda: client.get("/activities", headers=headers),
    }

    response = requests[scenario]()

    assert response.status_code in (200, 201, 404, 422)

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
