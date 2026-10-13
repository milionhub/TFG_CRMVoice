"""
G.3 — Persistencia de conversaciones (services.chat_store): propiedad por
comercial, historial acotado, estado activo revalidado y conexiones cortas.
"""
import json
import sqlite3

import pytest

import db
from services import chat_store
from services.chat_store import ChatState, Conversation, ConversationNotFound


@pytest.fixture
def crm(factory):
    rivera = factory.client("Rivera Industrial S.L.", alias="Rivera")
    sierra = factory.client("Sierra Norte S.A.", alias="Sierra Norte")
    marta = factory.contact(rivera, "Marta López")
    return type("Crm", (), {"rivera": rivera, "sierra": sierra, "marta": marta})


def save(conversation, user, text="pregunta", answer="respuesta", metadata=None, client=None, contact=None):
    return chat_store.save_turn(conversation, user["id"], text, answer, metadata or {"tools": [], "error": None},
                                client, contact)


def test_sin_id_es_una_conversacion_nueva_sin_fila(user_a, dbq):
    conversation = chat_store.load_conversation(None, user_a["id"])

    assert conversation == Conversation(id=None)
    assert dbq.one("SELECT COUNT(*) AS n FROM chat_conversations")["n"] == 0


def test_guardar_crea_y_continuar_carga_historial_y_estado(user_a, crm):
    conversation_id, state = save(Conversation(id=None), user_a, "¿Cómo va Rivera?", "Va bien",
                                  client=crm.rivera, contact=crm.marta)
    assert state == ChatState(client={"id": crm.rivera, "name": "Rivera Industrial S.L."},
                              contact={"id": crm.marta, "name": "Marta López", "client_id": crm.rivera})

    loaded = chat_store.load_conversation(conversation_id, user_a["id"])
    assert loaded.id == conversation_id and loaded.state == state
    assert loaded.history == [{"role": "user", "content": "¿Cómo va Rivera?"},
                              {"role": "assistant", "content": "Va bien"}]

    same_id, _ = save(loaded, user_a, "¿Y Sierra?", "Bien también", client=crm.sierra)
    assert same_id == conversation_id
    again = chat_store.load_conversation(conversation_id, user_a["id"])
    assert again.state.client_id == crm.sierra and again.state.contact is None
    assert len(again.history) == 4


def test_metadata_del_asistente_se_guarda_como_json(user_a, dbq):
    metadata = {"tools": [{"name": "find_entities", "args": {"client_name": "X"}, "status": "ok", "found": False}],
                "error": None}
    conversation_id, _ = save(Conversation(id=None), user_a, metadata=metadata)

    rows = dbq.all("SELECT role, metadata FROM chat_messages WHERE conversation_id = ? ORDER BY id",
                   (conversation_id,))
    assert [r["role"] for r in rows] == ["user", "assistant"]
    assert rows[0]["metadata"] is None and json.loads(rows[1]["metadata"]) == metadata


def test_conversacion_ajena_o_inexistente_mismo_error(user_a, user_b):
    conversation_id, _ = save(Conversation(id=None), user_a)

    for conversation_id_, user in [(conversation_id, user_b), (conversation_id + 1000, user_a)]:
        with pytest.raises(ConversationNotFound) as info:
            chat_store.load_conversation(conversation_id_, user["id"])
        assert str(info.value) == ""  # sin detalle que distinga los dos casos


def test_no_se_puede_guardar_en_una_conversacion_ajena(user_a, user_b, dbq):
    conversation_id, _ = save(Conversation(id=None), user_a)

    with pytest.raises(ConversationNotFound):
        save(Conversation(id=conversation_id), user_b, "intruso")
    assert dbq.one("SELECT COUNT(*) AS n FROM chat_messages")["n"] == 2  # nada de B


def test_historial_acotado_recortado_y_sin_turnos_de_error(user_a):
    conversation = Conversation(id=None)
    for i in range(10):
        conversation_id, _ = save(conversation, user_a, f"pregunta {i}", f"respuesta {i} " + "x" * 3000)
        conversation = Conversation(id=conversation_id)
    save(conversation, user_a, "pregunta fallida", "El asistente no está disponible",
         metadata={"tools": [], "error": "ai_unavailable"})

    history = chat_store.load_conversation(conversation.id, user_a["id"]).history

    assert len(history) == chat_store.HISTORY_MESSAGES
    assert history[-1] == {"role": "user", "content": "pregunta fallida"}   # la pregunta sí, el error no
    assert all("no está disponible" not in m["content"] for m in history)
    assert history[0]["role"] == "assistant"  # orden cronológico
    assert all(len(m["content"]) <= chat_store.HISTORY_ASSISTANT_CHARS for m in history)


def test_estado_borrado_con_fk_activas_queda_en_null(user_a, crm):
    conversation_id, _ = save(Conversation(id=None), user_a, client=crm.rivera, contact=crm.marta)
    with db.connection() as conn:
        conn.execute("DELETE FROM clients WHERE id = ?", (crm.rivera,))  # ON DELETE SET NULL (y contacto en cascada)

    assert chat_store.load_conversation(conversation_id, user_a["id"]).state == ChatState()


def test_estado_obsoleto_sin_fk_se_limpia_al_cargar(user_a, crm, dbq):
    conversation_id, _ = save(Conversation(id=None), user_a, client=crm.rivera, contact=crm.marta)
    # Borrado con foreign_keys OFF (como un editor externo de SQLite): la FK no actúa
    raw = sqlite3.connect(db.DB_PATH)
    raw.execute("DELETE FROM contacts WHERE id = ?", (crm.marta,))
    raw.commit()
    raw.close()

    state = chat_store.load_conversation(conversation_id, user_a["id"]).state

    assert state.client_id == crm.rivera and state.contact is None
    row = dbq.one("SELECT active_client_id, active_contact_id FROM chat_conversations WHERE id = ?",
                  (conversation_id,))
    assert row == {"active_client_id": crm.rivera, "active_contact_id": None}


def test_contacto_de_otro_cliente_no_se_guarda(user_a, crm):
    _, state = save(Conversation(id=None), user_a, client=crm.sierra, contact=crm.marta)
    assert state.client_id == crm.sierra and state.contact is None


def test_estado_con_entidad_inexistente_se_guarda_vacio(user_a):
    _, state = save(Conversation(id=None), user_a, client=999, contact=998)
    assert state == ChatState()


@pytest.mark.parametrize("fails", [False, True], ids=["exito", "conversacion_ajena"])
def test_todas_las_conexiones_se_cierran(user_a, user_b, crm, monkeypatch, fails):
    conversation_id, _ = save(Conversation(id=None), user_a, client=crm.rivera)
    real = db.get_connection
    opened = []

    class Tracked:
        def __init__(self, conn):
            self.conn, self.closed = conn, False

        def close(self):
            self.closed = True
            self.conn.close()

        def __getattr__(self, name):
            return getattr(self.conn, name)

    def tracked():
        opened.append(Tracked(real()))
        return opened[-1]

    monkeypatch.setattr(db, "get_connection", tracked)
    owner = user_b if fails else user_a
    try:
        conversation = chat_store.load_conversation(conversation_id, owner["id"])
        save(conversation, owner)
    except ConversationNotFound:
        assert fails

    assert opened and all(c.closed for c in opened)
