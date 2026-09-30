"""
F.2 — Resolución contextual en el pipeline de voz (voice_pipeline.analyze_transcription).

- Un cliente dicho pero no resuelto NO se sustituye por el cliente del contacto.
- Solo se hereda el cliente de un contacto inequívoco cuando no se dijo ninguno.
- La ambigüedad y los conflictos se exponen (status, candidates, origen) sin elegir en silencio.
- La confianza solo pondera lo que es relevante para la frase (los productos, si se mencionan).
"""
from types import SimpleNamespace

import pytest

from services import voice_pipeline

@pytest.fixture
def crm(factory):
    nebula = factory.client("Nebula Logística S.L.", alias="Nebula")
    lumen = factory.client("Instituto Lumen", alias="Lumen")
    horizonte = factory.client("Clínica Horizonte S.L.", alias="Horizonte")
    return SimpleNamespace(
        nebula=nebula, lumen=lumen, horizonte=horizonte,
        nora=factory.contact(nebula, "Nora Quintana"),
        hugo=factory.contact(nebula, "Hugo Balmes"),
        teo=factory.contact(lumen, "Teo Arranz"),
        marta=factory.contact(horizonte, "Marta López"),
        vela=factory.product("Monitor Vela 24", aliases=["vela 24"]),
        orbe=factory.product("Portátil Orbe 16", aliases=["orbe 16"]),
    )


def analyze(text):
    return voice_pipeline.analyze_transcription(text)


def candidate_ids(body, key):
    return [c["id"] for c in body.get(key) or []]


# =====================================================================
# Cliente dicho, contacto, herencia
# =====================================================================

def test_cliente_explicito_y_contacto_del_mismo_cliente(crm):
    body = analyze("Llamar a Marta López de Clínica Horizonte")

    assert (body["cliente_id"], body["contacto_id"]) == (crm.horizonte, crm.marta)
    assert body.get("cliente_status") == "exact" and body.get("cliente_origen") == "detected"
    assert body.get("contacto_status") == "exact"
    assert candidate_ids(body, "cliente_candidates") == [crm.horizonte]
    assert body["resolution_status"] == "exact"


def test_cliente_explicito_inexistente_no_hereda_el_del_contacto(crm):
    """F-I2: el usuario dijo Acme; Nora es de Nebula. No se cambia Acme por Nebula."""
    body = analyze("Reunión con Nora Quintana de Acme mañana")

    assert body["cliente_id"] is None
    assert body.get("cliente_status") == "conflict" and body.get("cliente_origen") == "detected"
    assert body["cliente_detectado"] == "Acme"
    assert body["contacto_id"] == crm.nora and body.get("contacto_status") == "exact"
    assert body["resolution_status"] in {"low", "unresolved"}


def test_sin_cliente_dicho_se_hereda_el_del_contacto_marcado_como_heredado(crm):
    body = analyze("Llamar a Hugo mañana")

    assert body["cliente_id"] == crm.nebula
    assert body.get("cliente_status") == "inherited" and body.get("cliente_origen") == "inherited"
    assert body.get("cliente_candidates") == []
    # El cliente heredado vale menos que uno dicho: 100 (contacto) · 0.9
    assert body["cliente_confidence"] == 90
    assert body["contacto_id"] == crm.hugo


def test_contacto_de_otro_cliente_es_un_conflicto_y_no_se_asocia(crm):
    body = analyze("Reunión con Nora Quintana de Lumen")

    assert body["cliente_id"] == crm.lumen
    assert body["contacto_id"] is None and body["contacto_nombre"] is None
    assert body.get("contacto_status") == "conflict"
    assert candidate_ids(body, "contacto_candidates") == [crm.nora]   # existe, pero en Nebula


# =====================================================================
# Ambigüedad: no se elige ni se hereda
# =====================================================================

def test_contacto_ambiguo_sin_cliente_no_se_elige_ni_se_hereda(crm, factory):
    pastor = factory.contact(crm.lumen, "Nora Pastor")

    body = analyze("Reunión con Nora mañana")

    assert body["contacto_id"] is None and body.get("contacto_status") == "ambiguous"
    assert candidate_ids(body, "contacto_candidates") == [crm.nora, pastor]
    assert body["cliente_id"] is None
    assert body.get("cliente_status") == "unresolved" and body.get("cliente_origen") is None


def test_cliente_ambiguo_no_se_elige(crm, factory):
    other = factory.client("Nebula Consultores S.A.", alias="Nebula")

    body = analyze("Reunión con Hugo de Nebula")

    assert body["cliente_id"] is None and body.get("cliente_status") == "ambiguous"
    assert candidate_ids(body, "cliente_candidates") == [crm.nebula, other]
    assert body["resolution_status"] != "exact"


def test_candidates_son_json_limpio_como_maximo_3(crm, factory):
    for i in range(4):
        factory.contact(crm.lumen, f"Nora Prueba{i}")

    body = analyze("Reunión con Nora mañana")

    assert "contacto_candidates" in body
    candidates = body["contacto_candidates"]
    assert 2 <= len(candidates) <= 3
    assert all(set(c) == {"id", "nombre", "score"} for c in candidates)


# =====================================================================
# Confianza (F-I6)
# =====================================================================

def test_actividad_perfecta_sin_productos_no_se_penaliza(crm):
    body = analyze("Llamar a Marta López de Clínica Horizonte")

    assert body["products_detected"] == []
    assert body["overall_confidence"] == 100


def test_con_producto_su_confianza_cuenta(crm):
    # "monitor bela 24" -> Monitor Vela 24 con 93.3: (40 + 30 + 0.2·93.3 + 10) / 1.0 ≈ 99
    body = analyze("Llamar a Marta López de Clínica Horizonte por el monitor bela 24")

    assert [p["product_id"] for p in body["products_detected"]] == [crm.vela]
    assert body["overall_confidence"] == 99


def test_varios_productos_cuentan_por_el_menos_seguro(crm):
    # Orbe 16 exacto (100) y "monitor bela 24" (93.3): cuenta el mínimo
    body = analyze("Llamar a Marta López de Clínica Horizonte por el orbe 16 y el monitor bela 24")

    assert {p["product_id"] for p in body["products_detected"]} == {crm.vela, crm.orbe}
    assert body["overall_confidence"] == 99
    assert body["resolution_status"] == "high"   # hay una entidad fuzzy: no es "exact"


def test_cliente_heredado_nunca_es_exact(crm):
    # (0.4·90 + 0.3·100 + 0.1·100) / 0.8 = 95, pero el cliente no se dijo
    body = analyze("Llamar a Hugo mañana")

    assert body["overall_confidence"] == 95
    assert body["resolution_status"] == "high"


def test_contacto_fuzzy_no_es_exact(crm):
    body = analyze("Llamar a Marta Lopes de Clínica Horizonte")

    assert body["contacto_id"] == crm.marta and body.get("contacto_status") == "fuzzy"
    assert body["resolution_status"] == "high"


def test_nada_resoluble_sigue_siendo_unresolved(crm):
    body = analyze("Llamar mañana a Pedro Ruiz de Acme")

    assert body["cliente_id"] is None and body["contacto_id"] is None
    assert body["resolution_status"] == "unresolved"
