"""db.connection(): commit si el bloque termina bien, rollback si falla y cierre siempre."""
import sqlite3

import pytest

import db


def count_salespeople() -> int:
    conn = db.get_connection()
    n = conn.execute("SELECT COUNT(*) FROM salespeople").fetchone()[0]
    conn.close()
    return n


def insert_salesperson(conn, email: str):
    conn.execute("INSERT INTO salespeople (nombre, email) VALUES (?, ?)", ("Test", email))


def test_commit_al_terminar_bien():
    with db.connection() as conn:
        insert_salesperson(conn, "commit@test.local")

    assert count_salespeople() == 1  # visible desde otra conexión


def test_rollback_si_el_bloque_lanza_y_propaga_la_excepcion():
    with pytest.raises(RuntimeError, match="fallo"):
        with db.connection() as conn:
            insert_salesperson(conn, "rollback@test.local")
            raise RuntimeError("fallo a mitad de la transacción")

    assert count_salespeople() == 0


def test_rollback_ante_error_de_sqlite():
    with pytest.raises(sqlite3.IntegrityError):
        with db.connection() as conn:
            insert_salesperson(conn, "dup@test.local")
            insert_salesperson(conn, "dup@test.local")  # email UNIQUE

    assert count_salespeople() == 0


@pytest.mark.parametrize("fails", [False, True], ids=["exito", "excepcion"])
def test_la_conexion_se_cierra_siempre(fails):
    captured = {}

    with pytest.raises(RuntimeError) if fails else _no_raise():
        with db.connection() as conn:
            captured["conn"] = conn
            if fails:
                raise RuntimeError("fallo")

    with pytest.raises(sqlite3.ProgrammingError):
        captured["conn"].execute("SELECT 1")  # cerrada


def test_usa_la_configuracion_de_get_connection():
    with db.connection() as conn:
        assert conn.row_factory is sqlite3.Row
        assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1


class _no_raise:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _RollbackFails:
    """Conexión real cuyo rollback falla (p. ej. conexión rota)."""

    def __init__(self, conn):
        self._conn = conn
        self.closed = False

    def rollback(self):
        raise sqlite3.OperationalError("rollback imposible")

    def close(self):
        self.closed = True
        self._conn.close()

    def __getattr__(self, name):
        return getattr(self._conn, name)


def test_si_el_rollback_falla_se_propaga_la_excepcion_original_y_se_cierra(monkeypatch):
    real_get_connection = db.get_connection
    opened = []

    def failing_rollback_connection():
        conn = _RollbackFails(real_get_connection())
        opened.append(conn)
        return conn

    monkeypatch.setattr(db, "get_connection", failing_rollback_connection)

    with pytest.raises(RuntimeError, match="error original"):
        with db.connection() as conn:
            insert_salesperson(conn, "rollback-roto@test.local")
            raise RuntimeError("error original")

    assert opened[0].closed
    monkeypatch.setattr(db, "get_connection", real_get_connection)
    assert count_salespeople() == 0  # sin commit: el cierre descarta la transacción


# =====================================================================
# G.3: tablas del chat (aditivas, con el mismo init_db)
# =====================================================================

CRM_TABLES = ("client_groups", "clients", "contacts", "products", "product_aliases", "activity_types",
              "salespeople", "activities", "activity_products", "activity_embeddings", "invoices",
              "invoice_lines")


def _dump(tables):
    conn = db.get_connection()
    try:
        return {t: [tuple(r) for r in conn.execute(f"SELECT * FROM {t} ORDER BY rowid")] for t in tables}
    finally:
        conn.close()


def _seed_crm(conn):
    client = conn.execute("INSERT INTO clients (razon_social) VALUES ('Cliente Previo S.L.')").lastrowid
    contact = conn.execute("INSERT INTO contacts (client_id, nombre) VALUES (?, 'Ana')", (client,)).lastrowid
    seller = conn.execute("INSERT INTO salespeople (nombre, email) VALUES ('V', 'v@test.local')").lastrowid
    conn.execute("INSERT INTO activities (client_id, contact_id, salesperson_id, comentario) VALUES (?, ?, ?, 'x')",
                 (client, contact, seller))
    invoice = conn.execute("INSERT INTO invoices (fecha, client_id) VALUES ('2026-01-01', ?)", (client,)).lastrowid
    conn.execute("INSERT INTO invoice_lines (invoice_id, total) VALUES (?, 10)", (invoice,))
    return client, contact, seller


def test_init_db_crea_las_tablas_del_chat():
    conn = db.get_connection()
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    conn.close()
    assert {"chat_conversations", "chat_messages"} <= tables


def test_init_db_sobre_una_bd_previa_a_g3_solo_anade_las_tablas_del_chat():
    conn = db.get_connection()
    conn.execute("DROP TABLE chat_messages")
    conn.execute("DROP TABLE chat_conversations")
    _seed_crm(conn)
    conn.commit()
    conn.close()
    before = _dump(CRM_TABLES)

    db.init_db()
    db.init_db()  # idempotente

    assert _dump(CRM_TABLES) == before
    assert _dump(("chat_conversations", "chat_messages")) == {"chat_conversations": [], "chat_messages": []}


def test_borrados_en_cascada_y_set_null_del_chat():
    with db.connection() as conn:
        client, contact, seller = _seed_crm(conn)
        conversation = conn.execute(
            "INSERT INTO chat_conversations (salesperson_id, active_client_id, active_contact_id) VALUES (?, ?, ?)",
            (seller, client, contact)).lastrowid
        conn.execute("INSERT INTO chat_messages (conversation_id, role, content) VALUES (?, 'user', 'hola')",
                     (conversation,))

    with db.connection() as conn:
        conn.execute("DELETE FROM activities")
        conn.execute("DELETE FROM invoices")
        conn.execute("DELETE FROM clients WHERE id = ?", (client,))  # contacts en cascada
    row = _dump(("chat_conversations",))["chat_conversations"][0]
    assert row[2:4] == (None, None)  # active_client_id, active_contact_id

    with db.connection() as conn:
        conn.execute("DELETE FROM salespeople WHERE id = ?", (seller,))
    assert _dump(("chat_conversations", "chat_messages")) == {"chat_conversations": [], "chat_messages": []}


def test_rol_de_mensaje_restringido():
    with db.connection() as conn:
        _, _, seller = _seed_crm(conn)
        conversation = conn.execute("INSERT INTO chat_conversations (salesperson_id) VALUES (?)",
                                    (seller,)).lastrowid

    with pytest.raises(sqlite3.IntegrityError):
        with db.connection() as conn:
            conn.execute("INSERT INTO chat_messages (conversation_id, role, content) VALUES (?, 'tool', '{}')",
                         (conversation,))
