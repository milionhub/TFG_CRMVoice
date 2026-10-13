"""
I.8 — Catálogo de productos (sin inventario).

- REST: listar, crear, editar y eliminar de forma segura (un producto usado
  por actividades, ventas o facturas no se borra: se conserva el histórico).
- Una sola fuente: un producto nuevo está disponible en actividades, ventas
  y en el Action Engine sin listas duplicadas.
- Action Engine: create_product y update_product con borrador, revisión,
  confirmación explícita e idempotente; nada se escribe antes de confirmar.
El intérprete (LLM) está simulado: se prueba lo determinista.
"""
import pytest

from conftest import make_interpretation as interp
from schemas.actions import Interpretation, ProductMention
from services.actions import interpreter as interpreter_module

MEETING = "Concertar reunión"


def product_names(client, user):
    return [p["name"] for p in client.get("/products", headers=user["headers"]).json()["products"]]


def create(client, user, name="Auriculares Nova", price="89,00"):
    return client.post("/products", json={"name": name, "price": price}, headers=user["headers"])


# =====================================================================
# REST: CRUD del catálogo
# =====================================================================

def test_crear_listar_editar_y_borrar(client, user_a, user_b, h2_crm, dbq):
    created = create(client, user_a)
    assert created.status_code == 201
    product = created.json()
    assert product == {"id": product["id"], "name": "Auriculares Nova", "price": 89.0}

    assert "Auriculares Nova" in product_names(client, user_b)            # catálogo compartido
    assert client.get(f"/products/{product['id']}", headers=user_a["headers"]).json() == product

    updated = client.put(f"/products/{product['id']}", json={"name": "Auriculares Nova Pro", "price": 79},
                         headers=user_a["headers"])
    assert updated.status_code == 200 and updated.json()["price"] == 79.0

    assert client.delete(f"/products/{product['id']}", headers=user_a["headers"]).status_code == 204
    assert client.get(f"/products/{product['id']}", headers=user_a["headers"]).status_code == 404
    assert "Auriculares Nova Pro" not in product_names(client, user_a)


def test_el_listado_conserva_su_contrato(client, user_a, h2_crm):
    products = client.get("/products", headers=user_a["headers"]).json()["products"]
    assert all(set(p) == {"id", "name", "price"} for p in products)       # sin stock ni campos nuevos
    assert [p["name"] for p in products] == sorted(p["name"] for p in products)


@pytest.mark.parametrize("body, field", [
    ({"name": "A", "price": "10"}, "name"),
    ({"name": "Webcam Orbit"}, "price"),
    ({"name": "Webcam Orbit", "price": "0"}, "price"),
    ({"name": "Webcam Orbit", "price": "-5"}, "price"),
    ({"name": "Webcam Orbit", "price": "4,500"}, "price"),                 # ambiguo: rechazado
    ({"name": "Webcam Orbit", "price": 12.5}, "price"),                    # floats no
    ({"name": "Webcam Orbit", "price": "10", "stock": 5}, "stock"),        # no hay inventario
])
def test_validaciones(client, user_a, h2_crm, body, field):
    response = client.post("/products", json=body, headers=user_a["headers"])
    assert response.status_code == 422
    assert field in str(response.json())


@pytest.mark.parametrize("name", ["Raton Faro", "ratón faro", "RATON-FARO", "Luna 13"])
def test_duplicado_por_nombre_o_alias(client, user_a, h2_crm, name):
    response = create(client, user_a, name=name)
    assert response.status_code == 409 and response.json()["code"] == "duplicate_name"


def test_editar_a_un_nombre_duplicado_se_rechaza(client, user_a, h2_crm):
    response = client.put(f"/products/{h2_crm.prado}", json={"name": "Raton Faro", "price": "980"},
                          headers=user_a["headers"])
    assert response.status_code == 409
    same = client.put(f"/products/{h2_crm.prado}", json={"name": "Portatil Prado 14", "price": "950"},
                      headers=user_a["headers"])
    assert same.status_code == 200                                         # su propio nombre no es duplicado


def test_no_se_borra_un_producto_con_historico(client, user_a, h2_crm, factory, dbq):
    factory.activity(h2_crm.a, h2_crm.rivera, products=[(h2_crm.luna, "Luna 13")])
    response = client.delete(f"/products/{h2_crm.luna}", headers=user_a["headers"])
    assert response.status_code == 409 and response.json()["code"] == "product_in_use"
    assert "actividades" in response.json()["detail"]
    assert dbq.one("SELECT COUNT(*) AS n FROM products WHERE id = ?", (h2_crm.luna,))["n"] == 1
    assert dbq.one("SELECT COUNT(*) AS n FROM product_aliases WHERE product_id = ?", (h2_crm.luna,))["n"] == 1


def test_no_se_borra_un_producto_vendido(client, user_a, h2_crm):
    sale = client.post("/sales", json={"client_id": h2_crm.rivera, "lines": [
        {"product_id": h2_crm.raton, "quantity": 2, "amount": "44"}]}, headers=user_a["headers"])
    assert sale.status_code == 201
    response = client.delete(f"/products/{h2_crm.raton}", headers=user_a["headers"])
    assert response.status_code == 409 and "ventas" in response.json()["detail"]


def test_borrar_un_producto_sin_uso_borra_sus_alias(client, user_a, h2_crm, factory, dbq):
    product = factory.product("Webcam Orbit", 65.0, aliases=["orbit"])
    assert client.delete(f"/products/{product}", headers=user_a["headers"]).status_code == 204
    assert dbq.one("SELECT COUNT(*) AS n FROM product_aliases WHERE product_id = ?", (product,))["n"] == 0


@pytest.mark.parametrize("method, path", [("get", "/products/999"), ("put", "/products/999"),
                                          ("delete", "/products/999")])
def test_inexistente_404(client, user_a, h2_crm, method, path):
    kwargs = {"json": {"name": "Webcam Orbit", "price": "65"}} if method == "put" else {}
    assert getattr(client, method)(path, headers=user_a["headers"], **kwargs).status_code == 404


@pytest.mark.parametrize("method, path", [("post", "/products"), ("put", "/products/1"), ("delete", "/products/1"),
                                          ("get", "/products/1")])
def test_sin_sesion_401(client, method, path):
    kwargs = {"json": {"name": "Webcam Orbit", "price": "65"}} if method in ("post", "put") else {}
    assert getattr(client, method)(path, **kwargs).status_code == 401


# =====================================================================
# Una sola fuente: disponible en actividades, ventas y Action Engine
# =====================================================================

def test_producto_nuevo_disponible_en_actividades(client, user_a, h2_crm, dbq, fake_embedding):
    product = create(client, user_a).json()
    response = client.post("/activities", json={
        "client_id": h2_crm.rivera, "activity_type_id": h2_crm.reunion, "datetime": "2026-10-05T10:00",
        "status": "pending", "product_ids": [product["id"]], "comment": "Presentar los auriculares"},
        headers=user_a["headers"])
    assert response.status_code == 201
    assert dbq.one("SELECT product_id FROM activity_products")["product_id"] == product["id"]


def test_producto_nuevo_disponible_en_ventas(client, user_a, h2_crm, dbq):
    product = create(client, user_a).json()
    response = client.post("/sales", json={"client_id": h2_crm.rivera, "lines": [
        {"product_id": product["id"], "quantity": 3, "amount": "267"}]}, headers=user_a["headers"])
    assert response.status_code == 201
    row = dbq.one("SELECT product_id, quantity, amount_cents FROM sales")
    assert (row["product_id"], row["quantity"], row["amount_cents"]) == (product["id"], 3, 26700)


def test_producto_nuevo_lo_resuelve_el_action_engine(client, user_a, h2_crm, interpreter, frozen_now):
    create(client, user_a)
    interpreter.script(interp(contact_name="Marta Lopez", activity_type=MEETING, date="2026-10-02", time="17:00",
                              status="pending", products=[], comment="Hablar de los auriculares"))
    draft = client.post("/actions/interpret", json={"text": "Reunión con Marta López para hablar de los "
                                                            "Auriculares Nova"}, headers=user_a["headers"]).json()
    assert [p["label"] for p in draft["fields"]["products"]] == ["Auriculares Nova"]
    assert draft["confirmable"] is True


def test_renombrar_conserva_las_relaciones_historicas(client, user_a, h2_crm, factory, dbq):
    activity = factory.activity(h2_crm.a, h2_crm.rivera, products=[(h2_crm.luna, "Luna 13")])
    client.post("/sales", json={"client_id": h2_crm.rivera, "lines": [
        {"product_id": h2_crm.luna, "quantity": 1, "amount": "790"}]}, headers=user_a["headers"])

    renamed = client.put(f"/products/{h2_crm.luna}", json={"name": "Portatil Luna 13 Pro", "price": "749"},
                         headers=user_a["headers"])
    assert renamed.status_code == 200
    assert dbq.one("SELECT product_id FROM activity_products WHERE activity_id = ?",
                   (activity,))["product_id"] == h2_crm.luna
    assert dbq.one("SELECT product_id, amount_cents FROM sales")["amount_cents"] == 79000   # la venta no cambia
    listed = client.get("/sales", headers=user_a["headers"]).json()
    assert "Portatil Luna 13 Pro" in str(listed)


# =====================================================================
# Action Engine: create_product
# =====================================================================

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
    def _patch(draft, edits, revision=None):
        return client.patch(f"/actions/{draft['id']}", json={"revision": revision or draft["revision"],
                                                               "edits": edits}, headers=user_a["headers"])
    return _patch


@pytest.fixture
def confirm(client, user_a):
    def _confirm(draft, revision=None):
        return client.post(f"/actions/{draft['id']}/confirm", json={"revision": revision or draft["revision"]},
                           headers=user_a["headers"])
    return _confirm


def new_product(name="Auriculares Nova", price="89.00"):
    return interp(action_type="create_product", product=ProductMention(name=name, price=price, new_name=None))


def change_product(name="Auriculares Nova", price=None, new_name=None):
    return interp(action_type="update_product", product=ProductMention(name=name, price=price, new_name=new_name))


def issues_of(draft):
    return {(i["field"], i["code"], i["blocking"]) for i in draft["issues"]}


def test_crear_producto_por_voz(run, confirm, h2_crm, dbq):
    draft = run(new_product(), "Crea un producto llamado Auriculares Nova con un PVP de 89 euros.")
    assert draft["action_type"] == "create_product"
    assert draft["fields"] == {"name": "Auriculares Nova", "price_cents": 8900, "price_said": "89.00",
                               "price_error": None}
    assert draft["confirmable"] is True and draft["issues"] == []

    response = confirm(draft)
    assert response.status_code == 200
    result = response.json()["result"]
    assert result["entity"] == "product" and result["data"]["name"] == "Auriculares Nova"
    assert dbq.one("SELECT nombre, precio FROM products WHERE id = ?", (result["ids"][0],))["precio"] == 89.0


def test_crear_producto_confirmar_dos_veces_es_idempotente(run, confirm, h2_crm, dbq):
    draft = run(new_product("Webcam Orbit", "65.00"), "Crea el producto Webcam Orbit por 65 euros.")
    first, second = confirm(draft), confirm(draft)
    assert first.status_code == second.status_code == 200
    assert first.json()["result"] == second.json()["result"]
    assert dbq.one("SELECT COUNT(*) AS n FROM products WHERE nombre = 'Webcam Orbit'")["n"] == 1


def test_crear_producto_normaliza_mayusculas_sin_cambiar_el_nombre(run, h2_crm):
    # Batería real: "CREA un producto llamado webcam orbit con un precio de 65€."
    draft = run(new_product("webcam orbit", "65.00"))
    assert draft["fields"]["name"] == "Webcam Orbit"
    # Con mayúsculas significativas se respeta tal cual
    assert run(new_product("webcam ORBIT hd", "65"))["fields"]["name"] == "webcam ORBIT hd"


def test_crear_producto_parecido_a_uno_existente_no_se_adivina(run, h2_crm):
    draft = run(new_product("Raton Faros", "20"))
    assert draft["fields"]["name"] == "Raton Faros" and draft["confirmable"] is True


def test_crear_producto_duplicado_bloquea(run, confirm, h2_crm, dbq):
    draft = run(new_product("ratón faro", "22"))
    assert ("name", "duplicate", True) in issues_of(draft) and draft["confirmable"] is False
    assert confirm(draft).status_code == 422
    assert dbq.one("SELECT COUNT(*) AS n FROM products")["n"] == 4


@pytest.mark.parametrize("price, code", [(None, "missing"), ("cuatro", "invalid"), ("0", "invalid")])
def test_crear_producto_sin_pvp_valido_bloquea(run, h2_crm, price, code):
    draft = run(new_product("Webcam Orbit", price))
    assert ("price", code, True) in issues_of(draft) and draft["confirmable"] is False


def test_crear_producto_se_corrige_en_la_revision(run, patch, confirm, h2_crm, dbq):
    draft = run(new_product("Webcam Orbit", None))
    fixed = patch(draft, {"price": "65,50", "name": "Webcam Orbit 2"}).json()
    assert (fixed["fields"]["name"], fixed["fields"]["price_cents"]) == ("Webcam Orbit 2", 6550)
    assert fixed["confirmable"] is True and fixed["revision"] == 2
    assert confirm(draft).json()["code"] == "stale_revision"
    assert confirm(fixed).status_code == 200
    assert dbq.one("SELECT precio FROM products WHERE nombre = 'Webcam Orbit 2'")["precio"] == 65.5


def test_crear_producto_descartado_no_se_guarda(run, client, user_a, confirm, h2_crm, dbq):
    draft = run(new_product())
    assert client.post(f"/actions/{draft['id']}/cancel", headers=user_a["headers"]).status_code == 200
    assert confirm(draft).status_code == 409
    assert dbq.one("SELECT COUNT(*) AS n FROM products WHERE nombre = 'Auriculares Nova'")["n"] == 0


def test_el_esquema_del_interprete_no_tiene_stock():
    schema = interpreter_module._SCHEMA
    product = next(d for d in schema["$defs"].values() if d.get("title") == "ProductMention")
    assert set(product["properties"]) == {"name", "price", "new_name"} == set(product["required"])
    assert "stock" not in str(schema) and "inventory" not in str(schema)
    assert "product" in schema["required"]
    assert set(Interpretation.model_fields["action_type"].annotation.__args__) == {
        "create_activity", "create_client", "create_contact", "create_sale", "create_product", "update_product",
        "unsupported"}


# =====================================================================
# Action Engine: update_product
# =====================================================================

@pytest.fixture
def nova(factory, h2_crm):
    return factory.product("Auriculares Nova", 89.0)


def test_cambiar_el_precio(run, confirm, h2_crm, nova, dbq):
    draft = run(change_product(price="79.00"), "Cambia el precio de Auriculares Nova a 79 euros.")
    fields = draft["fields"]
    assert fields["product"]["id"] == nova and fields["product"]["match"] == "exact"
    assert (fields["current_name"], fields["current_price_cents"]) == ("Auriculares Nova", 8900)
    assert (fields["name"], fields["price_cents"]) == (None, 7900)            # solo lo que cambia
    assert draft["confirmable"] is True

    assert confirm(draft).status_code == 200
    row = dbq.one("SELECT nombre, precio FROM products WHERE id = ?", (nova,))
    assert (row["nombre"], row["precio"]) == ("Auriculares Nova", 79.0)


def test_renombrar(run, confirm, h2_crm, nova, dbq):
    draft = run(change_product(new_name="auriculares nova pro"), "Renombra Auriculares Nova a Auriculares Nova Pro.")
    assert draft["fields"]["name"] == "Auriculares Nova Pro" and draft["confirmable"] is True
    assert confirm(draft).status_code == 200
    row = dbq.one("SELECT nombre, precio FROM products WHERE id = ?", (nova,))
    assert (row["nombre"], row["precio"]) == ("Auriculares Nova Pro", 89.0)


def test_lo_que_no_cambia_se_toma_al_confirmar(run, client, user_a, confirm, h2_crm, nova, dbq):
    draft = run(change_product(price="79"))
    client.put(f"/products/{nova}", json={"name": "Auriculares Nova 2026", "price": "85"}, headers=user_a["headers"])
    assert confirm(draft).status_code == 200
    row = dbq.one("SELECT nombre, precio FROM products WHERE id = ?", (nova,))
    assert (row["nombre"], row["precio"]) == ("Auriculares Nova 2026", 79.0)   # el nombre editado no se pisa


def test_producto_aproximado_seguro(run, h2_crm, nova):
    draft = run(change_product(name="auriculares noba", price="79"))
    product = draft["fields"]["product"]
    assert product["id"] == nova and product["match"] == "fuzzy" and draft["confirmable"] is True
    assert ("product", "fuzzy_match", False) in issues_of(draft)              # visible: «Has dicho…»


def test_producto_ambiguo_pide_eleccion_y_se_elige(run, patch, h2_crm, factory, nova):
    pro = factory.product("Auriculares Nova Pro", 119.0)
    draft = run(change_product(name="Auriculares", price="79"))
    assert draft["fields"]["product"]["problem"] == "ambiguous" and draft["confirmable"] is False
    assert {c["id"] for c in draft["fields"]["product"]["candidates"]} == {nova, pro}

    chosen = patch(draft, {"product_id": pro}).json()
    assert chosen["fields"]["product"]["match"] == "user_selected"
    assert chosen["fields"]["current_price_cents"] == 11900 and chosen["confirmable"] is True


def test_producto_inexistente_no_se_inventa(run, h2_crm):
    draft = run(change_product(name="Webcam Orbit", price="79"))
    assert draft["fields"]["product"]["id"] is None and draft["fields"]["product"]["problem"] == "not_found"
    assert draft["confirmable"] is False


def test_sin_cambios_bloquea(run, h2_crm, nova):
    draft = run(change_product())
    assert ("changes", "missing", True) in issues_of(draft) and draft["confirmable"] is False


def test_renombrar_a_un_nombre_existente_bloquea(run, h2_crm, nova):
    draft = run(change_product(new_name="Raton Faro"))
    assert ("name", "duplicate", True) in issues_of(draft) and draft["confirmable"] is False


def test_producto_borrado_antes_de_confirmar(run, client, user_a, confirm, h2_crm, nova):
    draft = run(change_product(price="79"))
    assert client.delete(f"/products/{nova}", headers=user_a["headers"]).status_code == 204
    response = confirm(draft)
    assert response.status_code == 422
    assert response.json()["draft"]["confirmable"] is False


def test_un_cambio_confirmado_no_se_reejecuta(run, patch, confirm, client, user_a, h2_crm, nova, dbq):
    draft = run(change_product(price="79"))
    assert confirm(draft).status_code == 200
    client.put(f"/products/{nova}", json={"name": "Auriculares Nova", "price": "99"}, headers=user_a["headers"])
    assert confirm(draft).status_code == 200                                  # devuelve el resultado guardado
    assert dbq.one("SELECT precio FROM products WHERE id = ?", (nova,))["precio"] == 99.0
    assert patch(draft, {"price": "10"}).status_code == 409


def test_el_producto_dicho_sale_del_texto_si_el_interprete_no_lo_da(run, h2_crm, nova):
    draft = run(change_product(name=None, price="79"), "Pon los Auriculares Nova a 79 euros")
    assert draft["fields"]["product"]["id"] == nova
