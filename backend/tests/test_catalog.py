"""
Catálogo CRM (D.4): /clients, /contacts, /products, /activity-types y
/client-context.

Clientes, contactos, productos y tipos de actividad son un catálogo GLOBAL
compartido por todos los comerciales (sin propietario): no se filtran por
usuario. Lo que sí es privado son las actividades: /client-context debe
contar solo las del comercial autenticado. La facturación es global (las
facturas no tienen propietario asignado).
"""
from types import SimpleNamespace

import pytest


@pytest.fixture
def crm(factory):
    """Catálogo determinista, insertado en orden NO alfabético a propósito."""
    orion = factory.client("Orion Consultoría S.L.", alias="Orion")
    nebula = factory.client("Nebula Logística S.L.", alias="Nebula")
    aurora = factory.client("Clínica Aurora S.L.")
    return SimpleNamespace(
        orion=orion, nebula=nebula, aurora=aurora,
        nora=factory.contact(nebula, "Nora Quintana"),
        hugo=factory.contact(nebula, "Hugo Balmes"),
        alma=factory.contact(orion, "Alma Ferrer"),
        vela=factory.product("Monitor Vela 24", 189.0, aliases=["vela 24"]),
        aster=factory.product("Portátil Aster 14", 849.0),
        licencia=factory.product("Licencia Suite", 120.0),
    )


# ---------------------------------------------------------------------
# /clients
# ---------------------------------------------------------------------

def test_clients_lista_id_y_nombre_ordenados_por_razon_social(client, user_a, crm):
    response = client.get("/clients", headers=user_a["headers"])

    assert response.status_code == 200
    assert response.json() == {"clients": [
        {"id": crm.aurora, "name": "Clínica Aurora S.L."},
        {"id": crm.nebula, "name": "Nebula Logística S.L."},
        {"id": crm.orion, "name": "Orion Consultoría S.L."},
    ]}


def test_clients_catalogo_vacio(client, user_a):
    assert client.get("/clients", headers=user_a["headers"]).json() == {"clients": []}


def test_clients_es_catalogo_global_igual_para_todos(client, user_a, user_b, crm):
    assert (client.get("/clients", headers=user_a["headers"]).json()
            == client.get("/clients", headers=user_b["headers"]).json())


# ---------------------------------------------------------------------
# /contacts
# ---------------------------------------------------------------------

def test_contacts_sin_filtro_lista_todos_ordenados_por_nombre(client, user_a, crm):
    response = client.get("/contacts", headers=user_a["headers"])

    assert response.status_code == 200
    assert response.json() == {"contacts": [
        {"id": crm.alma, "name": "Alma Ferrer"},
        {"id": crm.hugo, "name": "Hugo Balmes"},
        {"id": crm.nora, "name": "Nora Quintana"},
    ]}


def test_contacts_filtrados_por_cliente_solo_de_ese_cliente(client, user_a, crm):
    nebula = client.get("/contacts", headers=user_a["headers"], params={"client_id": crm.nebula}).json()
    orion = client.get("/contacts", headers=user_a["headers"], params={"client_id": crm.orion}).json()
    aurora = client.get("/contacts", headers=user_a["headers"], params={"client_id": crm.aurora}).json()

    assert nebula == {"contacts": [{"id": crm.hugo, "name": "Hugo Balmes"},
                                   {"id": crm.nora, "name": "Nora Quintana"}]}
    assert orion == {"contacts": [{"id": crm.alma, "name": "Alma Ferrer"}]}
    assert aurora == {"contacts": []}


def test_contacts_de_cliente_inexistente_lista_vacia(client, user_a, crm):
    response = client.get("/contacts", headers=user_a["headers"], params={"client_id": 99999})

    assert response.json() == {"contacts": []}


def test_contacts_es_catalogo_global_igual_para_todos(client, user_a, user_b, crm):
    params = {"client_id": crm.nebula}
    assert (client.get("/contacts", headers=user_a["headers"], params=params).json()
            == client.get("/contacts", headers=user_b["headers"], params=params).json())


# ---------------------------------------------------------------------
# /products y /activity-types
# ---------------------------------------------------------------------

def test_products_lista_id_nombre_y_precio_ordenados(client, user_a, crm):
    response = client.get("/products", headers=user_a["headers"])

    assert response.status_code == 200
    assert response.json() == {"products": [
        {"id": crm.licencia, "name": "Licencia Suite", "price": 120.0},
        {"id": crm.vela, "name": "Monitor Vela 24", "price": 189.0},
        {"id": crm.aster, "name": "Portátil Aster 14", "price": 849.0},
    ]}


def test_products_es_catalogo_global_igual_para_todos(client, user_a, user_b, crm):
    assert (client.get("/products", headers=user_a["headers"]).json()
            == client.get("/products", headers=user_b["headers"]).json())


def test_activity_types_son_los_datos_de_referencia(client, user_a):
    import db

    response = client.get("/activity-types", headers=user_a["headers"])

    assert response.status_code == 200
    names = [t["name"] for t in response.json()["activity_types"]]
    assert names == sorted(db.ACTIVITY_TYPES)


# ---------------------------------------------------------------------
# /client-context: catálogo global + actividades privadas
# ---------------------------------------------------------------------

@pytest.fixture
def context_data(factory, user_a, user_b, crm):
    reunion = factory.activity_type_id("Concertar reunión")
    llamada = factory.activity_type_id("Realizar llamada de seguimiento")
    factory.activity(user_a["id"], crm.nebula, activity_type_id=reunion,
                     datetime_iso="2026-09-10T10:00:00", comentario="A: primera")
    factory.activity(user_a["id"], crm.nebula, activity_type_id=reunion,
                     datetime_iso="2026-09-20T10:00:00", comentario="A: segunda")
    for day in (21, 22, 23):
        factory.activity(user_b["id"], crm.nebula, activity_type_id=llamada,
                         datetime_iso=f"2026-09-{day}T10:00:00", comentario=f"B: {day}")

    # Facturación (global): 2 facturas de Nebula por 5 x 189 + 2 x 849 = 2643
    import db
    conn = db.get_connection()
    for fecha, product, qty, price in (("2026-05-06", crm.vela, 5, 189.0), ("2026-06-17", crm.aster, 2, 849.0)):
        cur = conn.execute("INSERT INTO invoices (fecha, client_id) VALUES (?, ?)", (fecha, crm.nebula))
        conn.execute("INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (?, ?, ?, ?, ?)",
                     (cur.lastrowid, product, qty, price, qty * price))
    conn.commit()
    conn.close()


def test_client_context_solo_cuenta_actividades_del_usuario(client, user_a, user_b, crm, context_data):
    ctx_a = client.get(f"/client-context/{crm.nebula}", headers=user_a["headers"]).json()
    ctx_b = client.get(f"/client-context/{crm.nebula}", headers=user_b["headers"]).json()

    assert ctx_a["client_name"] == ctx_b["client_name"] == "Nebula Logística S.L."

    assert ctx_a["total_activities"] == 2
    assert ctx_a["last_contact_date"] == "2026-09-20T10:00:00"
    assert ctx_a["frequent_activity_type"] == "Concertar reunión"
    assert ctx_a["recent_activities"] == ["A: segunda", "A: primera"]

    assert ctx_b["total_activities"] == 3
    assert ctx_b["last_contact_date"] == "2026-09-23T10:00:00"
    assert ctx_b["frequent_activity_type"] == "Realizar llamada de seguimiento"
    assert all(c.startswith("B:") for c in ctx_b["recent_activities"])


def test_client_context_facturacion_es_global(client, user_a, user_b, crm, context_data):
    billing_a = client.get(f"/client-context/{crm.nebula}", headers=user_a["headers"]).json()["billing"]
    billing_b = client.get(f"/client-context/{crm.nebula}", headers=user_b["headers"]).json()["billing"]

    assert billing_a == billing_b == {
        "total_facturado": 2643.0,
        "total_facturas": 2,
        "ultima_factura": "2026-06-17",
        "ticket_medio": 1321.5,
        "producto_top": "Portátil Aster 14",
    }


def test_client_context_usuario_sin_actividades_en_el_cliente(client, make_user, crm, context_data):
    other = make_user("sin.actividad@test.local")

    ctx = client.get(f"/client-context/{crm.nebula}", headers=other["headers"]).json()

    assert ctx["total_activities"] == 0
    assert ctx["last_contact_date"] is None
    assert ctx["recent_activities"] == []
