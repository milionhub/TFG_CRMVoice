"""
H.6 — Integración final: un mismo comercial opera por CRUD (REST) y por Voice V2
(intérprete programado, sin OpenAI ni Whisper) y TODAS las vistas cuentan lo
mismo: ficha de cliente, dashboard, herramientas del chat y GET /activities.
Otro comercial no ve ni puede tocar nada privado. Facturas históricas y ventas
registradas nunca se mezclan; los importes son céntimos exactos.
"""
import pytest

import db
from conftest import H2_NOW, make_interpretation as interp
from schemas.actions import NewContactMention, SaleLineMention
from services import crm_tools
from services.crm_tools.sales import sales_summary  # noqa: F401 (contrato que usan overview y list_sales)

TODAY = H2_NOW.date().isoformat()          # 2026-10-01 (jueves)


def _sql(sql, params=()):
    conn = db.get_connection()
    try:
        cur = conn.execute(sql, params)
        conn.commit()
        return cur.lastrowid
    finally:
        conn.close()


@pytest.fixture
def clock(frozen_now, monkeypatch):
    import services.dashboard as dashboard_module
    monkeypatch.setattr(dashboard_module, "current_time", lambda: H2_NOW)
    return H2_NOW


@pytest.fixture
def scenario(client, user_a, h2_crm, interpreter, fake_embedding, clock):
    """Datos creados por los dos caminos (formulario y voz) + una factura histórica."""
    h = user_a["headers"]

    def ok(response, status=(200, 201)):
        assert response.status_code in status, response.json()
        return response.json()

    # --- CRUD (formularios H.3) ---
    contact = ok(client.post("/contacts", json={"client_id": h2_crm.rivera, "name": "Pedro García",
                                                "role": "responsable de obra"}, headers=h))
    pending = ok(client.post("/activities", headers=h, json={
        "client_id": h2_crm.rivera, "contact_id": contact["id"], "activity_type_id": h2_crm.reunion,
        "datetime": "2026-10-02T10:00", "status": "pending", "product_ids": [h2_crm.luna], "comment": "Demo"}))
    overdue = ok(client.post("/activities", headers=h, json={
        "client_id": h2_crm.rivera, "contact_id": None, "activity_type_id": h2_crm.llamada,
        "datetime": "2026-09-29T10:00", "status": "pending", "product_ids": [], "comment": "Llamar"}))
    cancelled = ok(client.post("/activities", headers=h, json={
        "client_id": h2_crm.rivera, "contact_id": None, "activity_type_id": h2_crm.presupuesto,
        "datetime": "2026-10-03T10:00", "status": "pending", "product_ids": [h2_crm.prado], "comment": "Anulada"}))
    ok(client.patch(f"/activities/{cancelled['id']}", json={"status": "cancelled"}, headers=h))
    sale = ok(client.post("/sales", headers=h, json={
        "client_id": h2_crm.rivera, "sale_date": TODAY, "lines": [
            {"product_id": h2_crm.luna, "quantity": 2, "amount": "1.500,50"},
            {"concept": "instalación", "amount": "99,99"}]}))

    # --- Voice V2: venta y actividad completada, confirmadas explícitamente ---
    interpreter.script(interp(action_type="create_sale", client_name="Rivera", sale_lines=[SaleLineMention(
        product_name="Luna 13", concept=None, quantity=1, amount="300.00", amount_is_unit_price=False)]))
    voice_sale = ok(client.post("/actions/interpret", json={"text": "He vendido un Luna 13 a Rivera por 300"},
                                headers=h))
    ok(client.post(f"/actions/{voice_sale['id']}/confirm", json={"revision": 1}, headers=h))
    interpreter.script(interp(client_name="Rivera", contact_name="Marta", activity_type="Realizar llamada de seguimiento",
                              date="2026-09-30", time="12:00", status="completed", products=["Luna 13"],
                              comment="Llamada hecha"))
    voice_done = ok(client.post("/actions/interpret", json={"text": "Ayer llamé a Marta de Rivera"}, headers=h))
    done = ok(client.post(f"/actions/{voice_done['id']}/confirm", json={"revision": 1}, headers=h))

    # --- Factura histórica (global, sin comercial) ---
    invoice = _sql("INSERT INTO invoices (fecha, client_id) VALUES ('2026-08-01', ?)", (h2_crm.rivera,))
    _sql("INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (?, NULL, 1, 1000, 1000)",
         (invoice,))
    return {"crm": h2_crm, "contact": contact, "pending": pending["id"], "overdue": overdue["id"],
            "cancelled": cancelled["id"], "done": done["result"]["ids"][0], "sale_ids": [s["id"] for s in sale["sales"]],
            "voice_sale_draft": voice_sale["id"], "voice_done_draft": voice_done["id"]}


MY_SALES_CENTS = 150_050 + 9_999 + 30_000           # formulario (2 líneas) + voz


def test_las_vistas_cuentan_lo_mismo(client, user_a, scenario):
    crm, h = scenario["crm"], user_a["headers"]

    # Ficha de cliente (H.3)
    detail = client.get(f"/clients/{crm.rivera}", headers=h).json()
    assert detail["revenue"]["my_sales_cents"] == MY_SALES_CENTS
    assert detail["revenue"]["invoices_cents"] == 100_000
    assert detail["revenue"]["total_cents"] == MY_SALES_CENTS + 100_000
    assert {c["name"]: c["role"] for c in detail["contacts"]}["Pedro García"] == "Responsable de obra"
    assert "Portatil Prado 14" not in [p["name"] for p in detail["discussed_products"]]   # solo en la cancelada

    # Dashboard (H.5)
    dash = client.get("/dashboard", headers=h).json()
    assert dash["activities"] == {"pending": 2, "overdue": 1, "upcoming": 1, "upcoming_7d": 1}
    assert [a["id"] for a in dash["next_activities"]] == [scenario["pending"]]
    assert dash["sales_month"]["total_cents"] == MY_SALES_CENTS and dash["sales_month"]["line_count"] == 3

    # Chat (H.5): mismos estados, mismas ventas, facturas aparte
    by_status = {s: {a["id"] for a in crm_tools.list_activities(user_a["id"], status=s, now=H2_NOW)["activities"]}
                 for s in ("pending", "overdue", "completed", "cancelled")}
    assert by_status == {"pending": {scenario["pending"], scenario["overdue"]}, "overdue": {scenario["overdue"]},
                         "completed": {scenario["done"]}, "cancelled": {scenario["cancelled"]}}
    overview = crm_tools.get_client_overview(crm.rivera, user_a["id"], now=H2_NOW)
    assert overview["activity"]["by_status"] == {"pending": 2, "overdue": 1, "completed": 1, "cancelled": 1}
    assert overview["activity"]["last_activity"]["id"] == scenario["done"]          # último contacto: la completada
    assert overview["activity"]["next_activity"]["id"] == scenario["pending"]        # no la cancelada del día 3
    assert overview["my_sales"]["total_cents"] == MY_SALES_CENTS
    assert overview["billing"]["total_billed"] == 1000
    sales = crm_tools.list_sales(user_a["id"], client_id=crm.rivera, date_from=TODAY, date_to=TODAY, now=H2_NOW)
    assert sales["summary"]["total_eur"] == "1900.49" and sales["summary"]["line_count"] == 3

    # Histórico/Calendario (GET /activities): estado y nombre oficial de producto, también para la de voz
    listed = {a["id"]: a for a in client.get("/activities", headers=h).json()["activities"]}
    assert listed[scenario["cancelled"]]["status"] == "cancelled"
    assert listed[scenario["done"]]["status"] == "completed"
    assert [p["name"] for p in listed[scenario["done"]]["products"]] == ["Portatil Luna 13"]
    assert [p["name"] for p in listed[scenario["pending"]]["products"]] == ["Portatil Luna 13"]


def test_voz_idempotente_y_cancelar_no_escribe(client, user_a, scenario, interpreter, dbq):
    h = user_a["headers"]
    again = client.post(f"/actions/{scenario['voice_sale_draft']}/confirm", json={"revision": 1}, headers=h)
    assert again.status_code == 200                                         # doble confirmación: mismo resultado
    assert dbq.one("SELECT COUNT(*) AS n FROM sales")["n"] == 3

    interpreter.script(interp(action_type="create_contact", client_name="Rivera",
                              new_contact=NewContactMention(name="Laura Díaz", role=None, email=None, phone=None)))
    draft = client.post("/actions/interpret", json={"text": "Añade a Laura Díaz en Rivera"}, headers=h).json()
    before = dbq.one("SELECT COUNT(*) AS n FROM contacts")["n"]
    assert client.post(f"/actions/{draft['id']}/cancel", headers=h).json()["status"] == "cancelled"
    assert client.post(f"/actions/{draft['id']}/confirm", json={"revision": 1}, headers=h).status_code == 409
    assert dbq.one("SELECT COUNT(*) AS n FROM contacts")["n"] == before


def test_otro_comercial_no_ve_ni_toca_nada_privado(client, user_b, scenario, dbq):
    crm, h = scenario["crm"], user_b["headers"]

    assert client.get("/activities", headers=h).json()["activities"] == []
    assert client.get("/sales", headers=h).json()["sales"] == []
    dash = client.get("/dashboard", headers=h).json()
    assert dash["activities"]["pending"] == 0 and dash["sales_month"]["total_cents"] == 0
    detail = client.get(f"/clients/{crm.rivera}", headers=h).json()           # el cliente es compartido...
    assert detail["sales"] == [] and detail["revenue"]["my_sales_cents"] == 0   # ...sus ventas y actividades no
    assert detail["revenue"]["invoices_cents"] == 100_000                      # la factura histórica es global
    assert crm_tools.list_sales(crm.b, now=H2_NOW)["summary"]["total_cents"] == 0
    assert crm_tools.list_activities(crm.b, status="pending", now=H2_NOW)["activities"] == []

    # Escrituras sobre datos ajenos: 404, igual que si no existieran
    sale_id, activity_id = scenario["sale_ids"][0], scenario["pending"]
    assert client.delete(f"/sales/{sale_id}", headers=h).status_code == 404
    assert client.patch(f"/activities/{activity_id}", json={"status": "completed"}, headers=h).status_code == 404
    assert client.delete(f"/activities/{activity_id}", headers=h).status_code == 404
    assert client.get(f"/actions/{scenario['voice_sale_draft']}", headers=h).status_code == 404
    assert dbq.one("SELECT COUNT(*) AS n FROM sales")["n"] == 3


def test_sin_sesion_todo_lo_nuevo_esta_protegido(client, scenario):
    for method, path in [("GET", "/dashboard"), ("GET", "/sales"), ("POST", "/sales"), ("GET", "/clients/1"),
                         ("POST", "/contacts"), ("PATCH", "/activities/1"), ("POST", "/actions/interpret"),
                         ("POST", "/actions/interpret-audio"), ("GET", "/actions/x"), ("POST", "/chat")]:
        assert client.request(method, path).status_code == 401, (method, path)
