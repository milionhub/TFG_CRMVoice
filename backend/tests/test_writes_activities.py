"""
H.2 — Actividades V2: contrato tipado (ActivityIn), estado, duplicados
deterministas, coherencia cliente↔contacto y PATCH de estado.
(El formato anterior de la app está en test_activities.py.)
"""
import pytest

import db
from schemas.crm import ActivityIn
from services.writes import Duplicate, NotFound, ValidationFailed
from services.writes import activities as activity_writes

NOW_ISO = "2026-10-01T09:00:00"


def body(crm, **overrides):
    data = {"client_id": crm.rivera, "contact_id": crm.marta, "activity_type_id": crm.llamada,
            "datetime": "2026-10-02T10:00", "status": "pending", "product_ids": [crm.luna],
            "comment": "Llamar a Marta por el Luna 13"}
    data.update(overrides)
    return data


def create(client, user, crm, **overrides):
    return client.post("/activities", json=body(crm, **overrides), headers=user["headers"])


def fields_codes(response):
    return [(i["field"], i["code"]) for i in response.json()["issues"]]


# =====================================================================
# Alta
# =====================================================================

def test_alta_v2(client, user_a, h2_crm, dbq, fake_embedding, frozen_now):
    response = create(client, user_a, h2_crm)

    assert response.status_code == 201
    created = response.json()
    assert created == {**created, "client_id": h2_crm.rivera, "contact_name": "Marta Lopez",
                       "activity_type": "Realizar llamada de seguimiento", "datetime": "2026-10-02T10:00:00",
                       "status": "pending", "products": [{"id": h2_crm.luna, "name": "Portatil Luna 13"}]}
    row = dbq.activity(created["id"])
    assert row["salesperson_id"] == user_a["id"] and row["status"] == "pending"
    assert row["updated_at"] == NOW_ISO
    # El embedding se generó después de guardar
    assert len(fake_embedding.calls) == 1 and len(dbq.embeddings(created["id"])) == 1


def test_alta_v2_aunque_falle_el_embedding(client, user_a, h2_crm, dbq, failing_embedding, frozen_now):
    response = create(client, user_a, h2_crm)

    assert response.status_code == 201
    assert dbq.activity(response.json()["id"]) is not None
    assert dbq.embeddings(response.json()["id"]) == []


def test_el_servicio_no_necesita_red(user_a, h2_crm, dbq, frozen_now):
    """Sin parchear OpenAI (cualquier llamada haría fallar el test): el alta en sí no usa la red."""
    created = activity_writes.create_activity(ActivityIn(**body(h2_crm)), user_a["id"], now=frozen_now)
    assert dbq.activity(created["id"])["comentario"] == "Llamar a Marta por el Luna 13"


@pytest.mark.parametrize("value,stored", [
    ("2026-10-02T10:00", "2026-10-02T10:00:00"),
    ("2026-10-02T10:00:30", "2026-10-02T10:00:30"),
    ("2026-10-02T10:00:30.000", "2026-10-02T10:00:30"),
    ("2026-10-02 10:00", "2026-10-02T10:00:00"),
])
def test_fecha_normalizada_sin_milisegundos(client, user_a, h2_crm, dbq, fake_embedding, frozen_now, value, stored):
    response = create(client, user_a, h2_crm, datetime=value)
    assert dbq.activity(response.json()["id"])["datetime_iso"] == stored


@pytest.mark.parametrize("value", ["2026-10-02", "mañana", "2026-13-02T10:00", "2026-10-02T25:00", ""])
def test_fecha_no_valida_422(client, user_a, h2_crm, frozen_now, value):
    response = create(client, user_a, h2_crm, datetime=value)
    assert response.status_code == 422 and fields_codes(response)[0][0] == "datetime"


@pytest.mark.parametrize("overrides,expected", [
    ({"client_id": 999}, ("client", "not_found")),
    ({"contact_id": 999}, ("contact", "not_found")),
    ({"activity_type_id": 999}, ("activity_type", "not_found")),
    ("producto_inexistente", ("products[1]", "not_found")),
    ({"activity_type_id": None}, ("activity_type_id", "missing")),
    ({"status": None}, ("status", "missing")),
    ({"status": "hecha"}, ("status", "invalid")),
    ({"product_ids": [1, 1]}, ("product_ids", "invalid")),
    ({"comment": "x" * 2001}, ("comment", "invalid")),
    ({"salesperson_id": 2}, ("salesperson_id", "invalid")),
])
def test_alta_invalida_422_sin_escribir(client, user_a, h2_crm, dbq, frozen_now, overrides, expected):
    if overrides == "producto_inexistente":
        overrides = {"product_ids": [h2_crm.luna, 999]}
    response = create(client, user_a, h2_crm, **overrides)

    assert response.status_code == 422
    assert expected in fields_codes(response)
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0


def test_contacto_de_otro_cliente_422(client, user_a, h2_crm, dbq, frozen_now):
    response = create(client, user_a, h2_crm, contact_id=h2_crm.carlos_r)   # Carlos Ruiz es de San Lucas

    assert response.status_code == 422
    assert fields_codes(response) == [("contact", "conflict")]
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0


def test_completada_en_el_futuro_no_es_valida(client, user_a, h2_crm, frozen_now):
    response = create(client, user_a, h2_crm, status="completed")
    assert response.status_code == 422 and fields_codes(response) == [("status", "invalid")]


def test_pendiente_vencida_y_cancelada_futura_se_aceptan(client, user_a, h2_crm, fake_embedding, frozen_now):
    assert create(client, user_a, h2_crm, datetime="2026-09-01T10:00", status="pending").status_code == 201
    assert create(client, user_a, h2_crm, datetime="2026-12-01T10:00", status="cancelled").status_code == 201
    assert create(client, user_a, h2_crm, datetime="2026-09-30T10:00", status="completed").status_code == 201


# =====================================================================
# Duplicados exactos (B2): deterministas y por comercial
# =====================================================================

def test_duplicado_exacto_409(client, user_a, h2_crm, dbq, fake_embedding, frozen_now):
    first = create(client, user_a, h2_crm).json()

    response = create(client, user_a, h2_crm, datetime="2026-10-02T10:00:45", comment="otro texto",
                      product_ids=[])      # mismo minuto: duplicado aunque cambien segundos, comentario o productos

    assert response.status_code == 409
    assert response.json()["code"] == "duplicate_activity" and response.json()["existing_id"] == first["id"]
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 1


def test_duplicado_con_contacto_nulo(client, user_a, h2_crm, fake_embedding, frozen_now):
    assert create(client, user_a, h2_crm, contact_id=None).status_code == 201
    assert create(client, user_a, h2_crm, contact_id=None).status_code == 409
    assert create(client, user_a, h2_crm).status_code == 201    # con contacto ya no es la misma


@pytest.mark.parametrize("change", [{"datetime": "2026-10-02T10:01"}, {"activity_type_id": "reunion"},
                                    {"client_id": "costa", "contact_id": None}])
def test_no_es_duplicado_si_cambia_algo_de_la_identidad(client, user_a, h2_crm, fake_embedding, frozen_now, change):
    create(client, user_a, h2_crm)
    change = {k: getattr(h2_crm, v) if isinstance(v, str) and hasattr(h2_crm, v) else v for k, v in change.items()}
    assert create(client, user_a, h2_crm, **change).status_code == 201


def test_duplicado_es_por_comercial(client, user_a, user_b, h2_crm, fake_embedding, frozen_now):
    assert create(client, user_a, h2_crm).status_code == 201
    assert create(client, user_b, h2_crm).status_code == 201


def test_una_cancelada_no_cuenta_como_duplicado(client, user_a, h2_crm, fake_embedding, frozen_now):
    create(client, user_a, h2_crm, status="cancelled")
    assert create(client, user_a, h2_crm).status_code == 201


# =====================================================================
# Edición V2 (PUT) y estado (PATCH)
# =====================================================================

@pytest.fixture
def mine(client, user_a, h2_crm, fake_embedding, frozen_now):
    return create(client, user_a, h2_crm).json()["id"]


def test_put_v2_sustitucion_completa(client, user_a, h2_crm, mine, dbq):
    new = body(h2_crm, client_id=h2_crm.sanlucas, contact_id=h2_crm.carlos_r, datetime="2026-09-20T12:00",
               status="completed", product_ids=[h2_crm.monitor], comment="Hecha")

    response = client.put(f"/activities/{mine}", json=new, headers=user_a["headers"])

    assert response.status_code == 200
    assert response.json() == {**response.json(), "client_id": h2_crm.sanlucas, "status": "completed",
                               "datetime": "2026-09-20T12:00:00", "comment": "Hecha",
                               "products": [{"id": h2_crm.monitor, "name": "Monitor Mar 24"}]}


def test_put_v2_no_es_duplicado_de_si_misma(client, user_a, h2_crm, mine):
    assert client.put(f"/activities/{mine}", json=body(h2_crm), headers=user_a["headers"]).status_code == 200


def test_put_v2_contacto_de_otro_cliente_422(client, user_a, h2_crm, mine, dbq):
    before = dbq.activity(mine)
    response = client.put(f"/activities/{mine}", json=body(h2_crm, contact_id=h2_crm.laura),
                          headers=user_a["headers"])
    assert response.status_code == 422 and fields_codes(response) == [("contact", "conflict")]
    assert dbq.activity(mine) == before


def test_put_v2_de_otro_comercial_404_aunque_el_cuerpo_no_sea_valido(client, user_b, h2_crm, mine, dbq):
    before = dbq.activity(mine)
    for payload in (body(h2_crm), {"datetime": "no"}):
        response = client.put(f"/activities/{mine}", json=payload, headers=user_b["headers"])
        assert response.status_code == 404 and response.json() == {"detail": "Actividad no encontrada"}
    assert dbq.activity(mine) == before


def test_patch_estado(client, user_a, h2_crm, factory, dbq, frozen_now):
    past = factory.activity(user_a["id"], h2_crm.rivera, datetime_iso="2026-09-30T10:00:00")
    conn = db.get_connection()
    conn.execute("UPDATE activities SET status = 'pending' WHERE id = ?", (past,))
    conn.commit()
    conn.close()

    response = client.patch(f"/activities/{past}", json={"status": "completed"}, headers=user_a["headers"])

    assert response.status_code == 200 and response.json()["status"] == "completed"
    assert dbq.activity(past)["updated_at"] == NOW_ISO


def test_patch_estado_idempotente(client, user_a, h2_crm, mine, dbq):
    stamp = dbq.activity(mine)["updated_at"]
    for _ in range(2):
        response = client.patch(f"/activities/{mine}", json={"status": "pending"}, headers=user_a["headers"])
        assert response.status_code == 200 and response.json()["status"] == "pending"
    assert dbq.activity(mine)["updated_at"] == stamp


def test_patch_completada_en_el_futuro_422(client, user_a, h2_crm, mine, dbq):
    response = client.patch(f"/activities/{mine}", json={"status": "completed"}, headers=user_a["headers"])
    assert response.status_code == 422 and fields_codes(response) == [("status", "invalid")]
    assert dbq.activity(mine)["status"] == "pending"


def test_patch_reactivar_una_cancelada_duplicada_409(client, user_a, h2_crm, mine):
    cancelled = create(client, user_a, h2_crm, status="cancelled").json()["id"]
    response = client.patch(f"/activities/{cancelled}", json={"status": "pending"}, headers=user_a["headers"])
    assert response.status_code == 409 and response.json()["existing_id"] == mine


@pytest.mark.parametrize("payload", [{"status": "hecha"}, {"status": "pending", "extra": 1}, {}])
def test_patch_cuerpo_no_valido_422(client, user_a, h2_crm, mine, payload):
    assert client.patch(f"/activities/{mine}", json=payload, headers=user_a["headers"]).status_code == 422


def test_patch_y_delete_de_otro_comercial_404(client, user_b, h2_crm, mine, dbq):
    assert client.patch(f"/activities/{mine}", json={"status": "cancelled"}, headers=user_b["headers"]).status_code == 404
    assert client.delete(f"/activities/{mine}", headers=user_b["headers"]).status_code == 404
    assert dbq.activity(mine)["status"] == "pending"


def test_listado_con_estado_y_filtro(client, user_a, h2_crm, mine, fake_embedding):
    create(client, user_a, h2_crm, datetime="2026-12-01T10:00", status="cancelled")
    listed = client.get("/activities", headers=user_a["headers"]).json()["activities"]
    assert sorted(a["status"] for a in listed) == ["cancelled", "pending"]
    pending = client.get("/activities", params={"status": "pending"}, headers=user_a["headers"]).json()
    assert [a["id"] for a in pending["activities"]] == [mine]


# =====================================================================
# Servicio: transacción del llamador y errores de dominio
# =====================================================================

def test_con_conexion_del_llamador_la_transaccion_es_suya(user_a, h2_crm, dbq, frozen_now):
    conn = db.get_connection()
    conn.execute("BEGIN IMMEDIATE")
    activity_writes.create_activity(ActivityIn(**body(h2_crm)), user_a["id"], conn=conn, now=frozen_now)
    conn.execute("ROLLBACK")
    conn.close()
    assert dbq.one("SELECT COUNT(*) AS n FROM activities")["n"] == 0


def test_errores_de_dominio_del_servicio(user_a, user_b, h2_crm, frozen_now):
    created = activity_writes.create_activity(ActivityIn(**body(h2_crm)), user_a["id"], now=frozen_now)
    with pytest.raises(Duplicate):
        activity_writes.create_activity(ActivityIn(**body(h2_crm)), user_a["id"], now=frozen_now)
    with pytest.raises(ValidationFailed):
        activity_writes.create_activity(ActivityIn(**body(h2_crm, contact_id=h2_crm.laura)), user_a["id"],
                                        now=frozen_now)
    with pytest.raises(NotFound):
        activity_writes.set_activity_status(created["id"], "cancelled", user_b["id"], now=frozen_now)
