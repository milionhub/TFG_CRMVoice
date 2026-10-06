"""
H.5.2 (tirada 1) — Chat IA con estados y ventas reales; métricas de Home.

A. El chat ve activities.status: filtra por estado, marca vencidas y no
   presenta canceladas como compromisos ni contactos (listas, resúmenes,
   rankings, productos tratados y preparación de reunión).
B. El chat ve las ventas registradas DEL comercial, separadas de la
   facturación histórica, con importes exactos en céntimos.
E. GET /dashboard: autenticado, solo datos del comercial, sin canceladas.
Sin OpenAI: herramientas llamadas directamente y la ruta HTTP con el cliente de pruebas.
"""
from datetime import datetime

import pytest

import db
from services import chat_tools, crm_tools
from services.dashboard import dashboard

NOW = datetime(2026, 10, 15, 12, 0, 0)


def _sql(sql, params=()):
    conn = db.get_connection()
    try:
        cur = conn.execute(sql, params)
        conn.commit()
        return cur.lastrowid
    finally:
        conn.close()


def _status(activity_id, status):
    _sql("UPDATE activities SET status = ? WHERE id = ?", (status, activity_id))


def _sale(owner, client_id, cents, day, *, concept="Instalación"):
    return _sql("""
        INSERT INTO sales (salesperson_id, client_id, contact_id, product_id, quantity, amount_cents, sale_date,
                           concept, notes, created_at, updated_at)
        VALUES (?, ?, NULL, NULL, NULL, ?, ?, ?, NULL, ?, ?)
    """, (owner, client_id, cents, day, concept, day + "T10:00:00", day + "T10:00:00"))


def _invoice(client_id, total, day="2026-08-01"):
    invoice = _sql("INSERT INTO invoices (fecha, client_id) VALUES (?, ?)", (day, client_id))
    _sql("INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (?, NULL, 1, ?, ?)",
         (invoice, total, total))


@pytest.fixture
def world(factory, user_a, user_b, h2_crm):
    """Actividades de A con los tres estados (y vencidas) y una de B; ventas de A y B; una factura."""
    rivera, costa = h2_crm.rivera, h2_crm.costa
    ids = {
        "done": factory.activity(user_a["id"], rivera, datetime_iso="2026-10-10T10:00:00", comentario="Hecha",
                                 products=[(h2_crm.luna, "Luna 13")]),
        "overdue": factory.activity(user_a["id"], rivera, datetime_iso="2026-10-14T10:00:00", comentario="Vencida"),
        "cancelled_past": factory.activity(user_a["id"], rivera, datetime_iso="2026-10-13T10:00:00",
                                           comentario="Cancelada pasada", products=[(h2_crm.prado, "Prado")]),
        "next": factory.activity(user_a["id"], rivera, datetime_iso="2026-10-16T09:00:00", comentario="Próxima"),
        "cancelled_future": factory.activity(user_a["id"], rivera, datetime_iso="2026-10-15T15:00:00",
                                             comentario="Cancelada futura"),
        "far": factory.activity(user_a["id"], costa, datetime_iso="2026-11-20T09:00:00", comentario="Lejana"),
        "other_user": factory.activity(user_b["id"], rivera, datetime_iso="2026-10-16T08:00:00",
                                       comentario="De B"),
    }
    for key in ("overdue", "next", "far", "other_user"):
        _status(ids[key], "pending")
    for key in ("cancelled_past", "cancelled_future"):
        _status(ids[key], "cancelled")
    _sale(user_a["id"], rivera, 150_050, "2026-10-02")          # 1.500,50 € este mes
    _sale(user_a["id"], rivera, 9_999, "2026-09-30")            # mes anterior
    _sale(user_a["id"], costa, 30_000, "2026-10-05")
    _sale(user_b["id"], rivera, 777_700, "2026-10-03")          # de B: nunca visible para A
    _invoice(rivera, 1200.0)
    return {"ids": ids, "crm": h2_crm}


# =====================================================================
# A — Estados en el chat
# =====================================================================

def test_list_activities_sin_status_excluye_canceladas_y_marca_vencidas(world, user_a):
    ids = world["ids"]
    result = crm_tools.list_activities(user_a["id"], client_id=world["crm"].rivera, now=NOW)
    listed = {a["id"]: a for a in result["activities"]}
    assert set(listed) == {ids["done"], ids["overdue"], ids["next"]}
    assert (listed[ids["overdue"]]["status"], listed[ids["overdue"]]["overdue"]) == ("pending", True)
    assert (listed[ids["next"]]["status"], listed[ids["next"]]["overdue"]) == ("pending", False)
    assert (listed[ids["done"]]["status"], listed[ids["done"]]["overdue"]) == ("completed", False)


@pytest.mark.parametrize("status,expected", [
    ("pending", {"overdue", "next", "far"}),
    ("overdue", {"overdue"}),
    ("completed", {"done"}),
    ("cancelled", {"cancelled_past", "cancelled_future"}),
])
def test_filtro_por_estado_solo_del_comercial(world, user_a, status, expected):
    result = crm_tools.list_activities(user_a["id"], status=status, now=NOW)
    assert {a["id"] for a in result["activities"]} == {world["ids"][k] for k in expected}
    assert result["filters"]["status"] == status


def test_agenda_proxima_no_incluye_canceladas(world, user_a):
    result = crm_tools.list_activities(user_a["id"], temporal_scope="upcoming", now=NOW)
    assert [a["id"] for a in result["activities"]] == [world["ids"]["next"], world["ids"]["far"]]


def test_status_invalido_es_error_controlado(world, user_a):
    with pytest.raises(crm_tools.ToolArgumentError):
        crm_tools.list_activities(user_a["id"], status="hecha", now=NOW)


def test_resumen_de_cliente_por_estado_y_ultimo_contacto_completado(world, user_a):
    overview = crm_tools.get_client_overview(world["crm"].rivera, user_a["id"], now=NOW)
    activity = overview["activity"]
    assert activity["by_status"] == {"pending": 2, "overdue": 1, "completed": 1, "cancelled": 2}
    assert (activity["total"], activity["past"], activity["upcoming"]) == (3, 2, 1)   # sin canceladas
    assert activity["last_activity"]["id"] == world["ids"]["done"]      # ni la vencida ni la cancelada
    assert activity["next_activity"]["id"] == world["ids"]["next"]      # no la cancelada de hoy a las 15:00
    # Productos tratados: el de la cancelada no cuenta
    assert [p["name"] for p in overview["products"]["discussed"]] == ["Portatil Luna 13"]


def test_rankings_no_cuentan_canceladas(world, user_a):
    counts = crm_tools.crm_rankings("activity_count", user_a["id"], now=NOW)["items"]
    assert {i["client"]["name"]: i["activity_count"] for i in counts} == {"Tecnologia Rivera SL": 3,
                                                                          "Diputacion Costa Verde": 1}
    inactivity = {i["client"]["name"]: i for i in crm_tools.crm_rankings("inactivity", user_a["id"], now=NOW)["items"]}
    assert inactivity["Tecnologia Rivera SL"]["last_past_activity_datetime"] == "2026-10-10T10:00:00"
    assert inactivity["Tecnologia Rivera SL"]["next_activity_datetime"] == "2026-10-16T09:00:00"
    products = crm_tools.crm_rankings("product_discussed", user_a["id"], now=NOW)["items"]
    assert [p["product"]["name"] for p in products] == ["Portatil Luna 13"]


def test_attention_ignora_actividades_canceladas(factory, user_a, h2_crm):
    only_cancelled = factory.activity(user_a["id"], h2_crm.sanlucas, datetime_iso="2026-10-10T10:00:00")
    _status(only_cancelled, "cancelled")
    items = {i["client"]["name"]: i for i in crm_tools.crm_rankings("attention", user_a["id"], limit=10,
                                                                     now=NOW)["items"]}
    assert "never_contacted" in items["Instituto San Lucas"]["signals"]


def test_reunion_sin_canceladas(world, user_a):
    context = crm_tools.prepare_meeting_context(world["crm"].rivera, user_a["id"], now=NOW)
    assert [a["id"] for a in context["recent_activities"]] == [world["ids"]["overdue"], world["ids"]["done"]]
    assert [a["id"] for a in context["upcoming_activities"]] == [world["ids"]["next"]]


def test_la_herramienta_del_chat_expone_estado_y_vencida(world, user_a):
    shaped = chat_tools.shape_list_activities(
        crm_tools.list_activities(user_a["id"], status="overdue", now=NOW))
    assert [(a["status"], a["overdue"]) for a in shaped["activities"]] == [("pending", True)]


# =====================================================================
# B — Ventas en el chat
# =====================================================================

def test_list_sales_solo_propias_con_total_exacto(world, user_a):
    rivera = world["crm"].rivera
    result = crm_tools.list_sales(user_a["id"], client_id=rivera, now=NOW)
    assert result["summary"]["total_cents"] == 150_050 + 9_999
    assert result["summary"]["total_eur"] == "1600.49"                  # exacto, sin float
    assert result["summary"]["line_count"] == 2
    assert {s["amount_eur"] for s in result["sales"]} == {"1500.50", "99.99"}
    assert all(s["client"]["id"] == rivera for s in result["sales"])
    assert "facturación histórica" in result["summary"]["source"]


def test_list_sales_por_periodo_y_sin_cliente(world, user_a):
    month = crm_tools.list_sales(user_a["id"], date_from="2026-10-01", date_to="2026-10-31", now=NOW)
    assert month["summary"]["total_cents"] == 150_050 + 30_000
    assert month["summary"]["total_eur"] == "1800.50"


def test_ventas_ajenas_invisibles(world, user_b):
    result = crm_tools.list_sales(user_b["id"], now=NOW)
    assert result["summary"]["total_cents"] == 777_700
    assert result["count"] == 1


def test_vista_de_cliente_separa_facturas_y_ventas(world, user_a):
    overview = crm_tools.get_client_overview(world["crm"].rivera, user_a["id"], now=NOW)
    assert overview["billing"]["total_billed"] == 1200.0                # solo facturas
    assert overview["my_sales"]["total_cents"] == 150_050 + 9_999       # solo ventas de A
    shaped = chat_tools.shape_client_overview(overview)
    assert shaped["my_sales"]["total_eur"] == "1600.49"
    assert shaped["billing"]["total_billed"] == 1200.0
    assert shaped["billing"]["source"] != shaped["my_sales"]["source"]


def test_list_sales_en_el_registro_del_chat_y_con_guardia_de_alcance():
    assert "list_sales" in chat_tools.REGISTRY
    assert "list_sales" in chat_tools.SCOPE_GUARDED_TOOLS


# =====================================================================
# E — Dashboard de Home
# =====================================================================

def test_dashboard_metricas_del_comercial(world, user_a):
    data = dashboard(user_a["id"], now=NOW)
    assert data["activities"] == {"pending": 3, "overdue": 1, "upcoming": 2, "upcoming_7d": 1}
    assert [a["id"] for a in data["next_activities"]] == [world["ids"]["next"], world["ids"]["far"]]
    assert data["next_activities"][0]["client_name"] == "Tecnologia Rivera SL"
    assert data["sales_month"] == {"month": "2026-10", "date_from": "2026-10-01", "date_to": "2026-10-31",
                                   "total_cents": 180_050, "line_count": 2}


def test_dashboard_vacio(user_a):
    data = dashboard(user_a["id"], now=NOW)
    assert data["activities"] == {"pending": 0, "overdue": 0, "upcoming": 0, "upcoming_7d": 0}
    assert data["next_activities"] == [] and data["sales_month"]["total_cents"] == 0


def test_dashboard_http_autenticado_y_aislado(client, world, user_a, user_b):
    assert client.get("/dashboard").status_code == 401
    mine = client.get("/dashboard", headers=user_a["headers"])
    theirs = client.get("/dashboard", headers=user_b["headers"])
    assert mine.status_code == theirs.status_code == 200
    assert world["ids"]["other_user"] not in [a["id"] for a in mine.json()["next_activities"]]
    assert set(mine.json()) == {"now", "activities", "next_activities", "sales_month"}


def test_dashboard_se_actualiza_tras_cambios(world, user_a):
    before = dashboard(user_a["id"], now=NOW)
    _status(world["ids"]["overdue"], "completed")
    _sale(user_a["id"], world["crm"].rivera, 1, "2026-10-15")
    after = dashboard(user_a["id"], now=NOW)
    assert after["activities"]["overdue"] == before["activities"]["overdue"] - 1
    assert after["sales_month"]["total_cents"] == before["sales_month"]["total_cents"] + 1
