"""
H.2 — Borradores: propiedad, caducidad, edición con revisión, cancelación y
confirmación segura (idempotente, atómica, revalidada contra la BD actual).
Incluye /actions/interpret-audio con Whisper e intérprete simulados.
"""
import threading
from datetime import timedelta

import pytest

import db
from conftest import H2_NOW, make_interpretation as interp
from schemas.actions import SaleLineMention
from services import actions as action_service
from services import voice_pipeline
from services.actions import drafts as draft_service
from services.openai_client import AIServiceError
from services.writes import sales as sale_writes

WAV = b"RIFF\x24\x00\x00\x00WAVEfmt " + b"\x00" * 64


def activity_interp(**fields):
    base = dict(client_name="Rivera", contact_name="Marta", activity_type="Realizar llamada de seguimiento",
                date="2026-10-02", time="10:00", status="pending", products=["Luna 13"], comment="Llamar a Marta")
    base.update(fields)
    return interp(**base)


def sale_interp(*lines):
    return interp(action_type="create_sale", client_name="Rivera", sale_lines=list(lines) or [SaleLineMention(
        product_name="Luna 13", concept=None, quantity=5, amount="4500.00", amount_is_unit_price=False)])


@pytest.fixture
def draft(client, user_a, h2_crm, interpreter, frozen_now):
    """Crea un borrador del comercial A con la interpretación dada (por defecto, una actividad)."""

    def _draft(interpretation=None, user=user_a):
        interpreter.script(interpretation or activity_interp())
        response = client.post("/actions/interpret", json={"text": "dictado"}, headers=user["headers"])
        assert response.status_code == 201, response.json()
        return response.json()

    return _draft


def confirm(client, user, draft_id, revision, **extra):
    return client.post(f"/actions/{draft_id}/confirm", json={"revision": revision, **extra}, headers=user["headers"])


def patch(client, user, draft_id, revision, edits):
    return client.patch(f"/actions/{draft_id}", json={"revision": revision, "edits": edits}, headers=user["headers"])


def count(dbq, table):
    return dbq.one(f"SELECT COUNT(*) AS n FROM {table}")["n"]


# =====================================================================
# Propiedad: el de otro comercial es indistinguible de uno inexistente
# =====================================================================

def test_el_borrador_es_del_comercial(client, user_a, user_b, draft, dbq):
    mine = draft()

    assert client.get(f"/actions/{mine['id']}", headers=user_a["headers"]).json() == mine
    responses = [client.get(f"/actions/{mine['id']}", headers=user_b["headers"]),
                 client.get("/actions/no-existe", headers=user_b["headers"]),
                 patch(client, user_b, mine["id"], 1, {"comment": "x"}),
                 confirm(client, user_b, mine["id"], 1),
                 client.post(f"/actions/{mine['id']}/cancel", headers=user_b["headers"])]
    assert {r.status_code for r in responses} == {404}
    assert {str(r.json()) for r in responses} == {"{'detail': 'Borrador no encontrado'}"}
    assert count(dbq, "activities") == 0
    assert dbq.one("SELECT status, revision FROM action_drafts") == {"status": "open", "revision": 1}


def test_id_no_enumerable(draft, dbq):
    first, second = draft(), draft(activity_interp(time="11:00"))
    assert len(first["id"]) >= 20 and first["id"] != second["id"]
    assert not first["id"].isdigit()


@pytest.mark.parametrize("method,path", [("post", "/actions/interpret"), ("get", "/actions/x"),
                                         ("patch", "/actions/x"), ("post", "/actions/x/confirm"),
                                         ("post", "/actions/x/cancel"), ("post", "/actions/interpret-audio")])
def test_sin_sesion_401(client, method, path):
    assert getattr(client, method)(path).status_code in (401, 403)


# =====================================================================
# Confirmación
# =====================================================================

def test_confirmar_crea_la_actividad_una_sola_vez(client, user_a, h2_crm, draft, dbq, fake_embedding):
    created = draft()

    first = confirm(client, user_a, created["id"], 1)
    second = confirm(client, user_a, created["id"], 1)       # doble clic / reintento

    assert first.status_code == second.status_code == 200
    assert first.json()["result"] == second.json()["result"]
    result = first.json()["result"]
    assert result["entity"] == "activity" and first.json()["draft"]["status"] == "executed"
    [row] = dbq.all("SELECT * FROM activities")
    assert result["ids"] == [row["id"]]
    assert (row["salesperson_id"], row["client_id"], row["contact_id"], row["activity_type_id"], row["status"],
            row["datetime_iso"]) == (user_a["id"], h2_crm.rivera, h2_crm.marta, h2_crm.llamada, "pending",
                                     "2026-10-02T10:00:00")
    assert row["transcripcion"] == "dictado" and row["cliente_raw"] == "Rivera"
    assert dbq.activity_products(row["id"]) == [{"product_id": h2_crm.luna, "product_raw": "Luna 13"}]
    assert len(fake_embedding.calls) == 1        # después del commit, una sola vez


def test_confirmar_con_el_embedding_caido_guarda_igual(client, user_a, draft, dbq, failing_embedding):
    created = draft()
    assert confirm(client, user_a, created["id"], 1).status_code == 200
    assert count(dbq, "activities") == 1 and count(dbq, "activity_embeddings") == 0


@pytest.mark.parametrize("make,entity,table,expected", [
    (lambda c: interp(action_type="create_client", new_client=__import__("schemas.actions", fromlist=["x"])
                      .NewClientMention(name="Construcciones Mediterraneo", alias=None, city="Alicante",
                                        province=None, group_name=None)), "client", "clients", 1),
    (lambda c: interp(action_type="create_contact", client_name="Rivera", new_contact=__import__(
        "schemas.actions", fromlist=["x"]).NewContactMention(name="Pedro Garcia", role="Obra", email=None,
                                                            phone=None)), "contact", "contacts", 1),
    (lambda c: sale_interp(), "sale", "sales", 1),
])
def test_confirmar_cada_tipo(client, user_a, h2_crm, draft, dbq, make, entity, table, expected):
    before = count(dbq, table)
    created = draft(make(h2_crm))

    response = confirm(client, user_a, created["id"], 1)

    assert response.status_code == 200 and response.json()["result"]["entity"] == entity
    assert count(dbq, table) == before + expected


def test_venta_de_varias_lineas_atomica(client, user_a, h2_crm, draft, dbq):
    created = draft(sale_interp(
        SaleLineMention(product_name="Luna 13", concept=None, quantity=5, amount="4500", amount_is_unit_price=False),
        SaleLineMention(product_name=None, concept="Instalación", quantity=None, amount="300", amount_is_unit_price=False)))

    response = confirm(client, user_a, created["id"], 1)

    assert response.status_code == 200 and len(response.json()["result"]["ids"]) == 2
    assert [(r["product_id"], r["amount_cents"], r["salesperson_id"]) for r in dbq.all("SELECT * FROM sales ORDER BY id")] \
        == [(h2_crm.luna, 450000, user_a["id"]), (None, 30000, user_a["id"])]


def test_un_fallo_al_escribir_no_deja_nada_y_el_borrador_sigue_abierto(client, user_a, h2_crm, draft, dbq, monkeypatch):
    created = draft(sale_interp(
        SaleLineMention(product_name="Luna 13", concept=None, quantity=1, amount="10", amount_is_unit_price=False),
        SaleLineMention(product_name="Ratón Faro", concept=None, quantity=1, amount="20", amount_is_unit_price=False)))
    real_insert, calls = sale_writes._insert, []

    def flaky(conn, *args):
        calls.append(1)
        if len(calls) == 2:   # la 2.ª línea viola un CHECK de la BD tras insertar la 1.ª
            conn.execute("INSERT INTO sales (salesperson_id, client_id, amount_cents, sale_date) VALUES (1, 1, 0, 'x')")
        return real_insert(conn, *args)

    monkeypatch.setattr(sale_writes, "_insert", flaky)
    response = confirm(client, user_a, created["id"], 1)

    assert response.status_code == 422
    assert count(dbq, "sales") == 0                      # ni la primera línea
    stored = dbq.one("SELECT status, revision, result FROM action_drafts")
    assert stored["status"] == "open" and stored["result"] is None
    assert response.json()["draft"]["status"] == "open"


def test_confirmar_solo_acepta_la_revision(client, user_a, h2_crm, draft, dbq):
    created = draft()
    for extra in ({"client_id": h2_crm.costa}, {"fields": {"comment": "otro"}}, {"action_type": "create_client"}):
        response = confirm(client, user_a, created["id"], 1, **extra)
        assert response.status_code == 422
    assert client.post(f"/actions/{created['id']}/confirm", json={}, headers=user_a["headers"]).status_code == 422
    assert count(dbq, "activities") == 0


def test_no_se_confirma_con_issues_bloqueantes(client, user_a, h2_crm, draft, dbq):
    created = draft(activity_interp(contact_name="Marta", client_name=None))   # Marta ambigua
    assert created["confirmable"] is False

    response = confirm(client, user_a, created["id"], 1)

    assert response.status_code == 422 and response.json()["draft"]["status"] == "open"
    assert count(dbq, "activities") == 0


def test_confirmaciones_simultaneas_una_sola_escritura(user_a, h2_crm, draft, dbq, fake_embedding):
    created = draft()
    barrier, results, errors = threading.Barrier(4), [], []

    def worker():
        try:
            barrier.wait()
            results.append(action_service.confirm_draft(created["id"], user_a["id"], 1, now=H2_NOW))
        except Exception as error:  # pragma: no cover - el test falla abajo
            errors.append(error)

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == []
    assert count(dbq, "activities") == 1
    assert len({str(r["result"]) for r in results}) == 1


# =====================================================================
# Revalidación al confirmar (la BD ha cambiado desde el borrador)
# =====================================================================

def _execute(sql, params=()):
    conn = db.get_connection()
    conn.execute(sql, params)
    conn.commit()
    conn.close()


def test_entidad_borrada_antes_de_confirmar(client, user_a, h2_crm, draft, dbq):
    created = draft()
    _execute("DELETE FROM product_aliases WHERE product_id = ?", (h2_crm.luna,))
    _execute("DELETE FROM products WHERE id = ?", (h2_crm.luna,))

    response = confirm(client, user_a, created["id"], 1)

    assert response.status_code == 422
    refreshed = response.json()["draft"]
    assert refreshed["revision"] == 2 and refreshed["status"] == "open" and refreshed["confirmable"] is False
    assert ("products[0]", "not_found") in {(i["field"], i["code"]) for i in refreshed["issues"]}
    assert count(dbq, "activities") == 0
    # La revisión vieja ya no sirve
    assert confirm(client, user_a, created["id"], 1).json()["code"] == "stale_revision"


def test_contacto_movido_a_otro_cliente_antes_de_confirmar(client, user_a, h2_crm, draft, dbq):
    created = draft()
    _execute("UPDATE contacts SET client_id = ? WHERE id = ?", (h2_crm.costa, h2_crm.marta))

    response = confirm(client, user_a, created["id"], 1)

    assert response.status_code == 422
    assert ("contact", "conflict") in {(i["field"], i["code"]) for i in response.json()["issues"]}
    assert count(dbq, "activities") == 0


def test_duplicado_creado_despues_del_borrador(client, user_a, h2_crm, draft, dbq, fake_embedding):
    created = draft()
    client.post("/activities", headers=user_a["headers"], json={
        "client_id": h2_crm.rivera, "contact_id": h2_crm.marta, "activity_type_id": h2_crm.llamada,
        "datetime": "2026-10-02T10:00", "status": "pending"})

    response = confirm(client, user_a, created["id"], 1)

    assert response.status_code == 422
    assert ("activity", "duplicate") in {(i["field"], i["code"]) for i in response.json()["issues"]}
    assert count(dbq, "activities") == 1


# =====================================================================
# Edición (PATCH): tipada, revisada y revalidada
# =====================================================================

def test_editar_sube_la_revision_y_recalcula(client, user_a, h2_crm, draft, dbq, fake_embedding):
    created = draft(activity_interp(time="11:00"))

    response = patch(client, user_a, created["id"], 1, {"time": "10:00", "comment": "Llamar a las 10"})

    assert response.status_code == 200
    edited = response.json()
    assert edited["revision"] == 2 and edited["fields"]["time"] == "10:00"
    assert edited["fields"]["comment"] == "Llamar a las 10" and edited["confirmable"] is True
    assert confirm(client, user_a, created["id"], 1).json()["code"] == "stale_revision"
    assert confirm(client, user_a, created["id"], 2).status_code == 200
    assert dbq.one("SELECT datetime_iso FROM activities")["datetime_iso"] == "2026-10-02T10:00:00"


def test_resolver_una_ambiguedad_con_un_candidato(client, user_a, h2_crm, draft):
    created = draft(activity_interp(client_name=None, contact_name="Marta"))
    [ambiguous] = [i for i in created["issues"] if i["code"] == "ambiguous"]
    choice = next(c["id"] for c in ambiguous["candidates"] if c["id"] == h2_crm.marta)

    edited = patch(client, user_a, created["id"], 1, {"contact_id": choice, "client_id": h2_crm.rivera}).json()

    assert edited["fields"]["contact"] == {**edited["fields"]["contact"], "id": h2_crm.marta, "match": "user_selected"}
    assert edited["confirmable"] is True


def test_editar_con_un_nombre_se_vuelve_a_resolver(client, user_a, h2_crm, draft):
    created = draft()
    edited = patch(client, user_a, created["id"], 1, {"client_name": "San Lucas", "contact_name": "Carlos"}).json()
    assert edited["fields"]["client"]["id"] == h2_crm.sanlucas and edited["fields"]["contact"]["id"] == h2_crm.carlos_r


def test_ids_manipulados_se_revalidan(client, user_a, h2_crm, draft, dbq):
    created = draft()

    foreign_contact = patch(client, user_a, created["id"], 1, {"contact_id": h2_crm.carlos_r}).json()
    assert ("contact", "conflict") in {(i["field"], i["code"]) for i in foreign_contact["issues"]}
    assert foreign_contact["confirmable"] is False

    missing = patch(client, user_a, created["id"], 2, {"client_id": 999, "product_ids": [999]}).json()
    assert {("client", "not_found"), ("products[0]", "not_found")} <= {(i["field"], i["code"]) for i in missing["issues"]}
    assert count(dbq, "activities") == 0


@pytest.mark.parametrize("edits", [{"action_type": "create_client"}, {"name": "Otra cosa"},
                                   {"lines": []}, {"payload": {}}, {}])
def test_no_se_puede_cambiar_el_tipo_ni_editar_campos_ajenos(client, user_a, draft, dbq, edits):
    created = draft()
    response = patch(client, user_a, created["id"], 1, edits)
    assert response.status_code == 422
    assert dbq.one("SELECT action_type, revision FROM action_drafts") == {"action_type": "create_activity",
                                                                         "revision": 1}


def test_edicion_con_revision_vieja_409(client, user_a, draft):
    created = draft()
    assert patch(client, user_a, created["id"], 1, {"comment": "uno"}).status_code == 200
    stale = patch(client, user_a, created["id"], 1, {"comment": "dos"})
    assert stale.status_code == 409 and stale.json()["code"] == "stale_revision"
    assert stale.json()["draft"]["fields"]["comment"] == "uno" and stale.json()["current_revision"] == 2


def test_editar_una_venta(client, user_a, h2_crm, draft):
    created = draft(sale_interp())
    edited = patch(client, user_a, created["id"], 1, {"lines": [
        {"product_id": h2_crm.prado, "quantity": 2, "amount": "1.960,00"}]}).json()
    assert edited["fields"]["lines"][0]["product"]["id"] == h2_crm.prado
    assert edited["fields"]["lines"][0]["amount_cents"] == 196000 and edited["confirmable"] is True


# =====================================================================
# Cancelación y caducidad
# =====================================================================

def test_cancelar(client, user_a, draft, dbq):
    created = draft()

    first = client.post(f"/actions/{created['id']}/cancel", headers=user_a["headers"])
    second = client.post(f"/actions/{created['id']}/cancel", headers=user_a["headers"])

    assert first.status_code == second.status_code == 200
    assert first.json()["status"] == second.json()["status"] == "cancelled"
    assert confirm(client, user_a, created["id"], 1).json()["code"] == "draft_cancelled"
    assert patch(client, user_a, created["id"], 1, {"comment": "x"}).status_code == 409
    assert count(dbq, "activities") == 0


def test_no_se_cancela_uno_ejecutado(client, user_a, draft, fake_embedding):
    created = draft()
    confirm(client, user_a, created["id"], 1)
    response = client.post(f"/actions/{created['id']}/cancel", headers=user_a["headers"])
    assert response.status_code == 409 and response.json()["code"] == "draft_executed"


def test_caducidad(client, user_a, draft, dbq, monkeypatch):
    created = draft()
    assert created["expires_at"] == "2026-10-01T09:30:00"
    later = H2_NOW + timedelta(minutes=31)
    import services.actions.drafts as drafts_module
    import services.actions.executor as executor_module
    for module in (drafts_module, executor_module):
        monkeypatch.setattr(module, "current_time", lambda: later)

    assert client.get(f"/actions/{created['id']}", headers=user_a["headers"]).status_code == 410
    assert confirm(client, user_a, created["id"], 1).status_code == 410
    assert patch(client, user_a, created["id"], 1, {"comment": "x"}).status_code == 410
    assert client.post(f"/actions/{created['id']}/cancel", headers=user_a["headers"]).status_code == 410
    assert count(dbq, "activities") == 0


def test_los_caducados_se_purgan_al_crear_otro(user_a, h2_crm, draft, dbq):
    old = draft()
    _execute("UPDATE action_drafts SET expires_at = '2026-09-29T00:00:00' WHERE public_id = ?", (old["id"],))
    draft(activity_interp(time="12:00"))
    assert [r["public_id"] for r in dbq.all("SELECT public_id FROM action_drafts")] != [old["id"]]
    assert old["id"] not in [r["public_id"] for r in dbq.all("SELECT public_id FROM action_drafts")]


def test_editar_renueva_la_caducidad(client, user_a, draft, monkeypatch):
    created = draft()
    import services.actions.drafts as drafts_module
    monkeypatch.setattr(drafts_module, "current_time", lambda: H2_NOW + timedelta(minutes=20))
    edited = patch(client, user_a, created["id"], 1, {"comment": "más tarde"}).json()
    assert edited["expires_at"] == "2026-10-01T09:50:00"


def test_get_devuelve_la_vista_sin_interpretacion(client, user_a, draft, dbq):
    created = draft()
    view = client.get(f"/actions/{created['id']}", headers=user_a["headers"]).json()
    assert set(view) == {"id", "action_type", "status", "revision", "source", "source_text", "fields", "issues",
                         "confirmable", "expired", "expires_at", "result", "created_at", "updated_at"}
    assert dbq.one("SELECT interpretation FROM action_drafts")["interpretation"]   # guardada solo para auditoría


# =====================================================================
# Audio: Whisper e intérprete simulados
# =====================================================================

def upload(client, user, content=WAV):
    return client.post("/actions/interpret-audio", files={"file": ("audio.wav", content, "audio/wav")},
                       headers=user["headers"])


def test_audio_crea_un_borrador_de_voz(client, user_a, h2_crm, interpreter, monkeypatch, dbq, business_counts,
                                       frozen_now):
    monkeypatch.setattr(voice_pipeline, "transcribe_audio",
                        lambda content, suffix: "  Mañana a las 10 llama a Marta de Rivera  ")
    interpreter.script(activity_interp())
    before = business_counts()

    response = upload(client, user_a)

    assert response.status_code == 201
    body = response.json()
    assert body["transcript"] == "Mañana a las 10 llama a Marta de Rivera"
    assert body["draft"]["source"] == "voice" and body["draft"]["source_text"] == body["transcript"]
    assert interpreter.calls[0][0] == body["transcript"]
    assert business_counts() == before


@pytest.mark.parametrize("transcript", ["", "   ", "...", "a"])
def test_audio_sin_contenido_422_sin_borrador(client, user_a, interpreter, monkeypatch, dbq, transcript):
    monkeypatch.setattr(voice_pipeline, "transcribe_audio", lambda content, suffix: transcript)
    response = upload(client, user_a)
    assert response.status_code == 422 and response.json()["issues"][0]["field"] == "transcript"
    assert interpreter.calls == [] and count(dbq, "action_drafts") == 0


def test_whisper_falla_503(client, user_a, interpreter, monkeypatch):
    def broken(content, suffix):
        raise RuntimeError("CUDA out of memory /secret/path")

    monkeypatch.setattr(voice_pipeline, "transcribe_audio", broken)
    response = upload(client, user_a)
    assert response.status_code == 503 and response.json()["code"] == "transcription_failed"
    assert "secret" not in response.text and "CUDA" not in response.text


def test_whisper_bien_pero_ia_caida_503_con_la_transcripcion(client, user_a, interpreter, monkeypatch, dbq,
                                                             frozen_now):
    monkeypatch.setattr(voice_pipeline, "transcribe_audio", lambda content, suffix: "Llama a Marta mañana")
    interpreter.script(AIServiceError("action_interpreter"))

    response = upload(client, user_a)

    assert response.status_code == 503
    assert response.json()["transcript"] == "Llama a Marta mañana" and response.json()["code"] == "ai_unavailable"
    assert count(dbq, "action_drafts") == 0 and count(dbq, "activities") == 0


@pytest.mark.parametrize("case,status", [("no_es_audio", 415), ("vacio", 400), ("demasiado_grande", 413)])
def test_audio_no_valido_se_rechaza_antes_de_whisper(client, user_a, monkeypatch, case, status):
    content = {"no_es_audio": b"no es audio", "vacio": b"",
               "demasiado_grande": b"RIFF" + b"x" * (10 * 1024 * 1024)}[case]
    called = []
    monkeypatch.setattr(voice_pipeline, "transcribe_audio", lambda *a: called.append(1) or "x")
    assert upload(client, user_a, content).status_code == status
    assert called == []


def test_servicio_de_borradores_es_independiente_de_http(user_a, h2_crm, interpreter, frozen_now, dbq,
                                                          fake_embedding):
    interpreter.script(activity_interp())
    view = action_service.interpret_text("dictado", user_a["id"], source="chat", now=H2_NOW)
    assert view["source"] == "chat"
    result = action_service.confirm_draft(view["id"], user_a["id"], 1, now=H2_NOW)
    assert result["result"]["entity"] == "activity" and count(dbq, "activities") == 1
    assert draft_service.get(view["id"], user_a["id"], now=H2_NOW)["status"] == "executed"
