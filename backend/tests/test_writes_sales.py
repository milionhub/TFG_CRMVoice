"""
H.2 — Ventas: una fila = una línea, importe total en céntimos (int), alta
atómica de 1 a 5 líneas, privadas del comercial, y la vista revenue_lines.
"""
import pytest

import db
from core.formats import FormatError, parse_money_cents
from services.writes import sales as sale_writes


# =====================================================================
# Importes en formato español (sin float)
# =====================================================================

@pytest.mark.parametrize("value,cents", [
    (4500, 450000),
    ("4500", 450000),
    ("4500.00", 450000),
    ("4500,00", 450000),
    ("4500,5", 450050),
    ("4.500", 450000),
    ("4.500,00", 450000),
    ("1.234.567,89", 123456789),
    ("4.50", 450),               # dos decimales con punto: decimal, no miles
    (" 4.500 € ", 450000),
    ("4500 euros", 450000),
    ("0,01", 1),
])
def test_importes_aceptados(value, cents):
    assert parse_money_cents(value) == cents


@pytest.mark.parametrize("value", [
    "4,500",                     # ambiguo: ¿4500 o 4,5? no se adivina
    "4,500.00",                  # formato inglés: no se acepta
    "4.5000",
    "45,001",
    "4500.123",                  # más de dos decimales
    "0", "0,00", "-10", "",
    "cuatro mil", "1e3",
    4500.5, 4500.0, True, None,  # float o tipos raros: nunca
    "20000000",                  # por encima del tope de cordura
])
def test_importes_rechazados(value):
    with pytest.raises(FormatError):
        parse_money_cents(value)


# =====================================================================
# Alta
# =====================================================================

def sale(crm, **overrides):
    data = {"client_id": crm.rivera, "sale_date": "2026-09-30",
            "lines": [{"product_id": crm.luna, "quantity": 5, "amount": "4.500"}]}
    data.update(overrides)
    return data


def post(client, user, data):
    return client.post("/sales", json=data, headers=user["headers"])


def sales_rows(dbq):
    return dbq.all("SELECT * FROM sales ORDER BY id")


def test_venta_de_una_linea(client, user_a, h2_crm, dbq, frozen_now):
    response = post(client, user_a, sale(h2_crm))

    assert response.status_code == 201
    [row] = sales_rows(dbq)
    assert response.json()["ids"] == [row["id"]]
    assert (row["salesperson_id"], row["client_id"], row["product_id"], row["quantity"], row["amount_cents"],
            row["sale_date"]) == (user_a["id"], h2_crm.rivera, h2_crm.luna, 5, 450000, "2026-09-30")
    assert isinstance(row["amount_cents"], int)
    # El precio de catálogo (5 x 790 = 3.950 €) no sustituye al importe indicado
    assert response.json()["sales"][0]["amount_cents"] == 450000


def test_venta_de_varias_lineas_atomica(client, user_a, h2_crm, dbq, frozen_now):
    data = sale(h2_crm, contact_id=h2_crm.marta, notes="Pedido septiembre", lines=[
        {"product_id": h2_crm.luna, "quantity": 5, "amount": "4500"},
        {"product_id": h2_crm.raton, "quantity": 5, "amount": 110},
        {"concept": "Instalación", "amount": "300,00"},
    ])

    response = post(client, user_a, data)

    assert response.status_code == 201
    rows = sales_rows(dbq)
    assert [(r["product_id"], r["concept"], r["amount_cents"]) for r in rows] == [
        (h2_crm.luna, None, 450000), (h2_crm.raton, None, 11000), (None, "Instalación", 30000)]
    assert {r["notes"] for r in rows} == {"Pedido septiembre"} and {r["contact_id"] for r in rows} == {h2_crm.marta}


def test_si_una_linea_falla_no_se_guarda_ninguna(client, user_a, h2_crm, dbq, frozen_now):
    data = sale(h2_crm, lines=[
        {"product_id": h2_crm.luna, "amount": "4500"},
        {"product_id": 999, "amount": "100"},
        {"amount": "50"},
    ])

    response = post(client, user_a, data)

    assert response.status_code == 422
    assert [(i["field"], i["code"]) for i in response.json()["issues"]] == [
        ("lines[1].product", "not_found"), ("lines[2].product", "missing")]
    assert sales_rows(dbq) == []


def test_si_falla_la_insercion_a_mitad_no_queda_nada(user_a, h2_crm, dbq, frozen_now, monkeypatch):
    """Atomicidad real: aunque la validación pase, un error al insertar la 2.ª línea deshace la 1.ª."""
    from schemas.crm import SaleCreate

    real_insert = sale_writes._insert
    calls = []

    def flaky(*args, **kwargs):
        calls.append(1)
        if len(calls) == 2:
            raise RuntimeError("fallo a mitad")
        return real_insert(*args, **kwargs)

    monkeypatch.setattr(sale_writes, "_insert", flaky)
    data = SaleCreate(**sale(h2_crm, lines=[{"product_id": h2_crm.luna, "amount": "1"},
                                           {"product_id": h2_crm.raton, "amount": "2"}]))
    with pytest.raises(RuntimeError):
        sale_writes.create_sales(data, user_a["id"], now=frozen_now)
    assert sales_rows(dbq) == []


@pytest.mark.parametrize("overrides,field", [
    ({"lines": []}, "lines"),
    ({"lines": [{"product_id": 1, "amount": "1"}] * 6}, "lines"),
    ({"lines": [{"product_id": 1, "quantity": 0, "amount": "1"}]}, "lines[0].quantity"),
    ({"lines": [{"product_id": 1, "amount": "0"}]}, "lines[0]"),
    ({"lines": [{"product_id": 1, "amount": 4500.5}]}, "lines[0].amount"),
    ({"lines": [{"product_id": 1, "amount": "4,500"}]}, "lines[0]"),
    ({"sale_date": "30/09/2026"}, "sale_date"),
    ({"salesperson_id": 2}, "salesperson_id"),
])
def test_forma_no_valida_422(client, user_a, h2_crm, dbq, overrides, field):
    response = post(client, user_a, sale(h2_crm, **overrides))

    assert response.status_code == 422
    assert any(i["field"].startswith(field) for i in response.json()["issues"]), response.json()["issues"]
    assert sales_rows(dbq) == []


def test_contacto_de_otro_cliente_422(client, user_a, h2_crm, dbq, frozen_now):
    response = post(client, user_a, sale(h2_crm, contact_id=h2_crm.carlos_r))
    assert response.status_code == 422
    assert [(i["field"], i["code"]) for i in response.json()["issues"]] == [("contact", "conflict")]


def test_fecha_futura_422_y_por_defecto_hoy(client, user_a, h2_crm, dbq, frozen_now):
    assert post(client, user_a, sale(h2_crm, sale_date="2026-10-02")).status_code == 422
    data = sale(h2_crm)
    del data["sale_date"]
    assert post(client, user_a, data).status_code == 201
    assert sales_rows(dbq)[0]["sale_date"] == "2026-10-01"


def test_cliente_inexistente_422(client, user_a, h2_crm, frozen_now):
    response = post(client, user_a, sale(h2_crm, client_id=999))
    assert [(i["field"], i["code"]) for i in response.json()["issues"]] == [("client", "not_found")]


# =====================================================================
# Propiedad, edición y borrado
# =====================================================================

@pytest.fixture
def a_sale(client, user_a, h2_crm, frozen_now):
    return post(client, user_a, sale(h2_crm)).json()["ids"][0]


def test_cada_comercial_solo_ve_sus_ventas(client, user_a, user_b, h2_crm, a_sale, frozen_now):
    post(client, user_b, sale(h2_crm, lines=[{"concept": "Venta de B", "amount": "10"}]))

    mine = client.get("/sales", headers=user_a["headers"]).json()
    theirs = client.get("/sales", headers=user_b["headers"]).json()

    assert [s["id"] for s in mine["sales"]] == [a_sale]
    assert [s["concept"] for s in theirs["sales"]] == ["Venta de B"]


def test_filtros_del_listado(client, user_a, h2_crm, a_sale, frozen_now):
    post(client, user_a, sale(h2_crm, client_id=h2_crm.costa, sale_date="2026-08-01"))
    headers = user_a["headers"]
    assert [s["id"] for s in client.get("/sales", params={"client_id": h2_crm.rivera}, headers=headers).json()["sales"]] == [a_sale]
    assert client.get("/sales", params={"from": "2026-09-01", "to": "2026-09-30"}, headers=headers).json()["count"] == 1
    assert client.get("/sales", params={"from": "01/09/2026"}, headers=headers).status_code == 422


def test_editar_venta(client, user_a, h2_crm, a_sale, dbq):
    response = client.put(f"/sales/{a_sale}", headers=user_a["headers"], json={
        "client_id": h2_crm.rivera, "sale_date": "2026-09-29", "concept": "Ajuste", "amount": "4.400,50"})

    assert response.status_code == 200
    row = dbq.one("SELECT * FROM sales WHERE id = ?", (a_sale,))
    assert (row["product_id"], row["concept"], row["amount_cents"], row["sale_date"]) == (None, "Ajuste", 440050,
                                                                                          "2026-09-29")
    assert row["updated_at"] == "2026-10-01T09:00:00"


def test_ventas_de_otro_comercial_404_igual_que_inexistentes(client, user_b, h2_crm, a_sale, dbq):
    update = {"client_id": h2_crm.rivera, "sale_date": "2026-09-29", "concept": "Robo", "amount": "1"}
    foreign_put = client.put(f"/sales/{a_sale}", headers=user_b["headers"], json=update)
    missing_put = client.put("/sales/999", headers=user_b["headers"], json=update)
    foreign_delete = client.delete(f"/sales/{a_sale}", headers=user_b["headers"])
    missing_delete = client.delete("/sales/999", headers=user_b["headers"])

    assert foreign_put.status_code == missing_put.status_code == 404
    assert foreign_put.json() == missing_put.json()
    assert foreign_delete.status_code == missing_delete.status_code == 404
    assert dbq.one("SELECT amount_cents FROM sales WHERE id = ?", (a_sale,))["amount_cents"] == 450000


def test_borrar_venta(client, user_a, h2_crm, a_sale, dbq):
    assert client.delete(f"/sales/{a_sale}", headers=user_a["headers"]).status_code == 204
    assert sales_rows(dbq) == []
    assert client.delete(f"/sales/{a_sale}", headers=user_a["headers"]).status_code == 404


# =====================================================================
# Vista de ingresos
# =====================================================================

def test_revenue_lines_combina_facturas_y_ventas_con_su_origen(client, user_a, h2_crm, a_sale, dbq):
    conn = db.get_connection()
    invoice = conn.execute("INSERT INTO invoices (fecha, client_id) VALUES ('2026-01-10', ?)", (h2_crm.rivera,)).lastrowid
    conn.execute("INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (?, ?, 8, 790, 6320.0)",
                 (invoice, h2_crm.luna))
    conn.commit()
    conn.close()

    lines = dbq.all("SELECT source, client_id, salesperson_id, amount_cents, day FROM revenue_lines ORDER BY source")

    assert lines == [
        {"source": "invoice", "client_id": h2_crm.rivera, "salesperson_id": None, "amount_cents": 632000,
         "day": "2026-01-10"},
        {"source": "sale", "client_id": h2_crm.rivera, "salesperson_id": user_a["id"], "amount_cents": 450000,
         "day": "2026-09-30"},
    ]
    # Las facturas históricas siguen intactas
    assert dbq.one("SELECT total FROM invoice_lines")["total"] == 6320.0


@pytest.mark.parametrize("method,path", [("get", "/sales"), ("post", "/sales"), ("put", "/sales/1"),
                                         ("delete", "/sales/1")])
def test_sin_sesion_401(client, method, path):
    kwargs = {"json": {}} if method in ("post", "put") else {}
    assert getattr(client, method)(path, **kwargs).status_code in (401, 403)
