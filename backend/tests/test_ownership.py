"""
Ownership / IDOR (P0): un usuario no puede leer, modificar ni borrar las
actividades de otro, ni verlas a través de la búsqueda semántica.
"""
import json
from types import SimpleNamespace

import pytest

from services import activities as activities_service
import semantic_search_service


# ---------------------------------------------------------------------
# Datos: A y B con actividades en el MISMO cliente (catálogo compartido)
# ---------------------------------------------------------------------

@pytest.fixture
def scenario(factory, user_a, user_b):
    nebula = factory.client("Nebula Test S.L.", alias="Nebula")
    nora = factory.contact(nebula, "Nora Test")
    monitor = factory.product("Monitor Test 24")
    licencia = factory.product("Licencia Test")
    a_activity = factory.activity(
        user_a["id"], nebula, contact_id=nora,
        comentario="Secreto comercial de A",
        products=[(monitor, "Monitor Test 24"), (licencia, "Licencia Test")],
        embedding=[1.0, 0.0, 0.0],
    )
    return SimpleNamespace(nebula=nebula, nora=nora, monitor=monitor, licencia=licencia,
                           a_activity=a_activity)


def snapshot(dbq, activity_id):
    """Estado completo de una actividad: fila, productos y embedding."""
    return {
        "activity": dbq.activity(activity_id),
        "products": dbq.activity_products(activity_id),
        "embeddings": dbq.embeddings(activity_id),
    }


# =====================================================================
# IDOR sobre /activities/{id}
# =====================================================================

def test_idor_b_no_puede_modificar_ni_borrar_la_actividad_de_a(client, user_a, user_b, scenario,
                                                               fake_embedding, dbq):
    before = snapshot(dbq, scenario.a_activity)
    assert before["activity"] is not None and len(before["products"]) == 2 and len(before["embeddings"]) == 1

    put = client.put(f"/activities/{scenario.a_activity}", headers=user_b["headers"], json={
        "fecha": "2030-01-01T00:00:00",
        "client_id": scenario.nebula,
        "contact_id": None,
        "activity_type_id": None,
        "comentario": "Sobrescrito por B",
        "products": [],
    })
    delete = client.delete(f"/activities/{scenario.a_activity}", headers=user_b["headers"])

    assert put.status_code == 404
    assert delete.status_code == 404
    # Nada ha cambiado: actividad, comentario, productos y embedding
    assert snapshot(dbq, scenario.a_activity) == before
    assert dbq.activity(scenario.a_activity)["comentario"] == "Secreto comercial de A"
    # El PUT rechazado ni siquiera llegó a regenerar el embedding
    assert fake_embedding.calls == []
    # A sigue viendo su actividad intacta
    listed = client.get("/activities", headers=user_a["headers"]).json()["activities"]
    assert [a["id"] for a in listed] == [scenario.a_activity]
    assert listed[0]["comentario"] == "Secreto comercial de A"


def test_idor_respuesta_identica_a_actividad_inexistente(client, user_b, scenario, fake_embedding):
    """B no puede distinguir 'existe pero es de otro' de 'no existe'."""
    other = client.delete(f"/activities/{scenario.a_activity}", headers=user_b["headers"])
    missing = client.delete("/activities/99999", headers=user_b["headers"])

    assert other.status_code == missing.status_code == 404
    assert other.json() == missing.json()


def test_idor_b_no_ve_la_actividad_de_a_ni_filtrando_por_su_cliente(client, user_b, scenario):
    response = client.get("/activities", headers=user_b["headers"], params={"client_id": scenario.nebula})

    assert response.json() == {"count": 0, "activities": []}


# =====================================================================
# Búsqueda semántica: solo actividades del usuario autenticado
# =====================================================================

@pytest.fixture
def semantic_data(factory, user_a, user_b, scenario):
    """
    Consulta = [1, 0, 0]. La actividad de B es la MÁS parecida (idéntica) a la
    consulta: si se colara en los resultados de A, aparecería la primera.
    """
    a_second = factory.activity(user_a["id"], scenario.nebula, comentario="Otra de A",
                                embedding=[0.6, 0.8, 0.0])
    b_activity = factory.activity(user_b["id"], scenario.nebula, comentario="Secreto comercial de B",
                                  embedding=[1.0, 0.0, 0.0])
    b_second = factory.activity(user_b["id"], scenario.nebula, comentario="Otra de B",
                                embedding=[0.9, 0.1, 0.0])
    return SimpleNamespace(a_ids={scenario.a_activity, a_second}, b_ids={b_activity, b_second})


def test_semantic_search_endpoint_solo_usa_actividades_del_usuario(client, user_a, user_b, monkeypatch,
                                                                    semantic_data):
    queries = []

    def fake_embedding(text):
        queries.append(text)
        return [1.0, 0.0, 0.0]

    monkeypatch.setattr(activities_service, "generate_embedding", fake_embedding)

    results_a = client.post("/semantic-search", json={"query": "secreto comercial"},
                            headers=user_a["headers"]).json()
    results_b = client.post("/semantic-search", json={"query": "secreto comercial"},
                            headers=user_b["headers"]).json()

    assert {r["id"] for r in results_a} == semantic_data.a_ids
    assert all("de B" not in r["comentario"] for r in results_a)
    assert {r["id"] for r in results_b} == semantic_data.b_ids
    assert all("de A" not in r["comentario"] for r in results_b)
    # Ordenados por similitud: lo más parecido de cada uno, primero
    assert results_a[0]["comentario"] == "Secreto comercial de A"
    assert results_b[0]["comentario"] == "Secreto comercial de B"
    assert queries == ["secreto comercial", "secreto comercial"]


def test_semantic_search_endpoint_usuario_sin_actividades(client, make_user, monkeypatch, semantic_data):
    monkeypatch.setattr(activities_service, "generate_embedding", lambda text: [1.0, 0.0, 0.0])
    empty_user = make_user("sin.actividades@test.local")

    response = client.post("/semantic-search", json={"query": "lo que sea"}, headers=empty_user["headers"])

    assert response.status_code == 200
    assert response.json() == []


def fake_openai_client(vector):
    """Doble del cliente OpenAI de semantic_search_service (lo usa el chat)."""
    response = SimpleNamespace(data=[SimpleNamespace(embedding=vector)])
    return SimpleNamespace(embeddings=SimpleNamespace(create=lambda **kwargs: response))


@pytest.mark.parametrize("with_client_filter", [False, True])
def test_semantic_search_service_del_chat_solo_usa_actividades_del_usuario(monkeypatch, user_a, user_b,
                                                                            scenario, semantic_data,
                                                                            with_client_filter):
    monkeypatch.setattr(semantic_search_service, "client", fake_openai_client([1.0, 0.0, 0.0]))
    client_id = scenario.nebula if with_client_filter else None

    results_a = semantic_search_service.semantic_search_activities("secreto", user_a["id"], client_id=client_id)
    results_b = semantic_search_service.semantic_search_activities("secreto", user_b["id"], client_id=client_id)

    assert {r["activity_id"] for r in results_a} == semantic_data.a_ids
    assert {r["activity_id"] for r in results_b} == semantic_data.b_ids


def test_embeddings_de_la_bd_del_test_son_json_de_floats(dbq, scenario):
    """Sanidad de la factoría: el formato coincide con el que escribe producción."""
    stored = dbq.embeddings(scenario.a_activity)[0]
    assert json.loads(stored["embedding_vector"]) == [1.0, 0.0, 0.0]
    assert stored["embedding_model"] == "text-embedding-3-small"
