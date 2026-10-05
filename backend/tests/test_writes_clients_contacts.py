"""
H.2 — Clientes y contactos V2 (POST/PUT /clients, POST/PUT /contacts, GET /clients/{id}).

Son datos COMPARTIDOS: cualquier comercial los ve y los edita; el creador se
guarda solo como auditoría (nunca filtra).
"""
import pytest


def post(client, user, path, body):
    return client.post(path, json=body, headers=user["headers"])


# =====================================================================
# Clientes
# =====================================================================

def test_alta_de_cliente_con_auditoria(client, user_a, h2_crm, dbq, frozen_now):
    response = post(client, user_a, "/clients", {"name": "  Construcciones Mediterraneo  ", "city": "Alicante",
                                                 "group_id": h2_crm.group, "email": "info@cm.es"})

    assert response.status_code == 201
    body = response.json()
    assert body == {**body, "name": "Construcciones Mediterraneo", "city": "Alicante", "group_id": h2_crm.group,
                    "group_name": "Empresa privada", "email": "info@cm.es", "warnings": []}
    row = dbq.one("SELECT * FROM clients WHERE id = ?", (body["id"],))
    assert row["razon_social"] == "Construcciones Mediterraneo" and row["poblacion"] == "Alicante"
    assert row["created_by_salesperson_id"] == user_a["id"]
    assert row["created_at"] == row["updated_at"] == "2026-10-01T09:00:00"


@pytest.mark.parametrize("name,alias", [
    ("Tecnologia Rivera SL", None),          # mismo nombre
    ("TECNOLOGÍA RIVERA, S.L.", None),       # sin tildes, mayúsculas, puntuación ni forma jurídica
    ("Tecnologia Rivera", None),             # sin la forma jurídica
    ("Rivera", None),                        # nombre = alias de otro
    ("Rivera Nueva", "Tecnologia Rivera SL"),  # alias = nombre de otro
    ("Otra Empresa", "rivera"),              # alias = alias de otro
])
def test_cliente_duplicado_409_sin_escribir(client, user_a, h2_crm, dbq, name, alias):
    before = dbq.one("SELECT COUNT(*) AS n FROM clients")["n"]

    response = post(client, user_a, "/clients", {"name": name, "alias": alias})

    assert response.status_code == 409
    body = response.json()
    assert body["code"] == "duplicate_client" and body["existing_id"] == h2_crm.rivera
    assert body["issues"][0]["candidates"] == [{"id": h2_crm.rivera, "label": "Tecnologia Rivera SL"}]
    assert dbq.one("SELECT COUNT(*) AS n FROM clients")["n"] == before


def test_cliente_parecido_se_guarda_con_aviso(client, user_a, h2_crm):
    """Decisión H.2: el parecido no bloquea un alta deliberada en el formulario; se avisa en "warnings"."""
    response = post(client, user_a, "/clients", {"name": "Tecnologia Riveras SL"})

    assert response.status_code == 201
    warnings = response.json()["warnings"]
    assert [(w["code"], w["blocking"]) for w in warnings] == [("similar", False)]
    assert warnings[0]["candidates"][0]["id"] == h2_crm.rivera


@pytest.mark.parametrize("body,field", [
    ({"name": "X"}, "name"),
    ({"name": "x" * 121}, "name"),
    ({"name": "Empresa", "email": "no-es-un-email"}, "email"),
    ({"name": "Empresa", "phone": "12"}, "phone"),
    ({"name": "Empresa", "owner": 1}, "owner"),
    ({}, "name"),
])
def test_cliente_invalido_422(client, user_a, h2_crm, body, field):
    response = post(client, user_a, "/clients", body)

    assert response.status_code == 422
    assert field in [i["field"] for i in response.json()["issues"]]


def test_cliente_con_grupo_inexistente_422(client, user_a, h2_crm):
    response = post(client, user_a, "/clients", {"name": "Empresa Nueva", "group_id": 999})

    assert response.status_code == 422
    assert [(i["field"], i["code"]) for i in response.json()["issues"]] == [("group", "not_found")]


def test_editar_cliente_compartido(client, user_a, user_b, h2_crm, dbq, frozen_now):
    created = post(client, user_a, "/clients", {"name": "Construcciones Mediterraneo"}).json()

    # Otro comercial puede editarlo (CRM compartido): el creador no cambia
    response = client.put(f"/clients/{created['id']}", headers=user_b["headers"],
                          json={"name": "Construcciones Mediterraneo SA", "city": "Elche"})

    assert response.status_code == 200 and response.json()["city"] == "Elche"
    row = dbq.one("SELECT * FROM clients WHERE id = ?", (created["id"],))
    assert row["created_by_salesperson_id"] == user_a["id"]
    # Conservar su propio nombre no es un duplicado; tomar el de otro, sí
    assert client.put(f"/clients/{created['id']}", headers=user_a["headers"],
                      json={"name": "Construcciones Mediterraneo SA"}).status_code == 200
    assert client.put(f"/clients/{created['id']}", headers=user_a["headers"],
                      json={"name": "Instituto San Lucas"}).status_code == 409


def test_editar_cliente_inexistente_404(client, user_a, h2_crm):
    assert client.put("/clients/999", headers=user_a["headers"], json={"name": "Nadie"}).status_code == 404


def test_buscar_clientes(client, user_a, h2_crm):
    response = client.get("/clients", params={"q": "RIVERA"}, headers=user_a["headers"])

    assert response.json() == {"clients": [{"id": h2_crm.rivera, "name": "Tecnologia Rivera SL"}]}
    by_alias = client.get("/clients", params={"q": "san luc"}, headers=user_a["headers"]).json()["clients"]
    assert [c["id"] for c in by_alias] == [h2_crm.sanlucas]


# =====================================================================
# Contactos
# =====================================================================

def test_alta_de_contacto(client, user_a, h2_crm, dbq, frozen_now):
    response = post(client, user_a, "/contacts", {"client_id": h2_crm.rivera, "name": "Pedro García",
                                                  "role": "Responsable de obra", "phone": "+34 600 000 000"})

    assert response.status_code == 201
    body = response.json()
    assert body == {**body, "client_id": h2_crm.rivera, "client_name": "Tecnologia Rivera SL",
                    "name": "Pedro García", "role": "Responsable de obra"}
    row = dbq.one("SELECT * FROM contacts WHERE id = ?", (body["id"],))
    assert row["created_by_salesperson_id"] == user_a["id"] and row["created_at"] == "2026-10-01T09:00:00"


def test_contacto_duplicado_en_el_mismo_cliente_409(client, user_a, h2_crm):
    response = post(client, user_a, "/contacts", {"client_id": h2_crm.rivera, "name": "MARTA LÓPEZ"})

    assert response.status_code == 409
    assert response.json()["code"] == "duplicate_contact" and response.json()["existing_id"] == h2_crm.marta


def test_mismo_nombre_en_otro_cliente_es_valido(client, user_a, h2_crm):
    assert post(client, user_a, "/contacts", {"client_id": h2_crm.sanlucas, "name": "Marta Lopez"}).status_code == 201


@pytest.mark.parametrize("body,field,code", [
    ({"client_id": 999, "name": "Pedro"}, "client", "not_found"),
    ({"name": "Pedro"}, "client_id", "missing"),
    ({"client_id": 1, "name": "P"}, "name", "invalid"),
    ({"client_id": 1, "name": "Pedro", "email": "pedro@"}, "email", "invalid"),
])
def test_contacto_invalido_422(client, user_a, h2_crm, body, field, code):
    response = post(client, user_a, "/contacts", body)

    assert response.status_code == 422
    assert (field, code) in [(i["field"], i["code"]) for i in response.json()["issues"]]


def test_editar_contacto_sin_cambiar_de_cliente(client, user_a, h2_crm, dbq):
    response = client.put(f"/contacts/{h2_crm.marta}", headers=user_a["headers"],
                          json={"name": "Marta López García", "role": "Compras"})
    assert response.status_code == 200 and response.json()["role"] == "Compras"

    # Moverlo a otro cliente no está permitido: 422 y nada cambia
    moved = client.put(f"/contacts/{h2_crm.marta}", headers=user_a["headers"],
                       json={"name": "Marta López García", "client_id": h2_crm.costa})
    assert moved.status_code == 422
    assert [i["field"] for i in moved.json()["issues"]] == ["client_id"]
    assert dbq.one("SELECT client_id FROM contacts WHERE id = ?", (h2_crm.marta,))["client_id"] == h2_crm.rivera


def test_editar_contacto_duplicado_o_inexistente(client, user_a, h2_crm):
    assert client.put(f"/contacts/{h2_crm.carlos_p}", headers=user_a["headers"],
                      json={"name": "Marta Lopez"}).status_code == 409
    assert client.put("/contacts/999", headers=user_a["headers"], json={"name": "Nadie"}).status_code == 404


# =====================================================================
# Ficha de cliente: compartida, pero actividades y ventas solo propias
# =====================================================================

def test_ficha_de_cliente_compartida_con_datos_propios(client, user_a, user_b, h2_crm, factory, dbq):
    factory.activity(user_a["id"], h2_crm.rivera, contact_id=h2_crm.marta, datetime_iso="2026-09-01T10:00:00",
                     comentario="De A", products=[(h2_crm.luna, "Luna 13")])
    factory.activity(user_b["id"], h2_crm.rivera, comentario="SECRETO DE B")
    conn = __import__("db").get_connection()
    invoice = conn.execute("INSERT INTO invoices (fecha, client_id) VALUES ('2026-01-10', ?)", (h2_crm.rivera,)).lastrowid
    conn.execute("INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (?, ?, 1, 100, 100.0)",
                 (invoice, h2_crm.luna))
    conn.execute("INSERT INTO sales (salesperson_id, client_id, product_id, amount_cents, sale_date) "
                 "VALUES (?, ?, ?, 450000, '2026-09-30')", (user_a["id"], h2_crm.rivera, h2_crm.luna))
    conn.execute("INSERT INTO sales (salesperson_id, client_id, concept, amount_cents, sale_date) "
                 "VALUES (?, ?, 'Venta de B', 99900, '2026-09-30')", (user_b["id"], h2_crm.rivera))
    conn.commit()
    conn.close()

    detail = client.get(f"/clients/{h2_crm.rivera}", headers=user_a["headers"]).json()

    assert detail["client"]["name"] == "Tecnologia Rivera SL"
    assert {c["name"] for c in detail["contacts"]} == {"Marta Lopez", "Carlos Perez"}
    assert [a["comment"] for a in detail["recent_activities"]] == ["De A"]
    assert [s["amount_cents"] for s in detail["sales"]] == [450000]
    assert detail["revenue"] == {**detail["revenue"], "invoices_cents": 10000, "my_sales_cents": 450000,
                                 "total_cents": 460000}
    assert [p["name"] for p in detail["discussed_products"]] == ["Portatil Luna 13"]
    assert "SECRETO DE B" not in str(detail) and "Venta de B" not in str(detail)

    # B ve el mismo cliente y contactos, pero solo lo suyo
    detail_b = client.get(f"/clients/{h2_crm.rivera}", headers=user_b["headers"]).json()
    assert detail_b["client"] == detail["client"] and detail_b["contacts"] == detail["contacts"]
    assert detail_b["revenue"]["my_sales_cents"] == 99900


def test_ficha_de_cliente_inexistente_404(client, user_a, h2_crm):
    assert client.get("/clients/999", headers=user_a["headers"]).status_code == 404


@pytest.mark.parametrize("method,path", [("post", "/clients"), ("put", "/clients/1"), ("get", "/clients/1"),
                                         ("post", "/contacts"), ("put", "/contacts/1")])
def test_sin_sesion_401(client, h2_crm, method, path):
    response = getattr(client, method)(path, json={"name": "x"}) if method != "get" else client.get(path)
    assert response.status_code in (401, 403)
