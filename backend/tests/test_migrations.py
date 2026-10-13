"""
H.2 — Migraciones versionadas (migrations.py + db.init_db).

Se parte de una base "v0" (el esquema anterior a H.2, sin migraciones) con
filas representativas en un fichero temporal: nunca backend/crm.db.
"""
import sqlite3
from datetime import datetime

import pytest

import db
import migrations

NOW = datetime(2026, 10, 1, 9, 0, 0)
BUSINESS = ("salespeople", "clients", "contacts", "products", "activity_products", "invoices", "invoice_lines")


@pytest.fixture
def v0_db(tmp_path, monkeypatch):
    """Base v0 en disco (bootstrap sin migraciones) con datos como los del CRM real."""
    path = tmp_path / "v0.db"
    monkeypatch.setattr(db, "DB_PATH", path)
    with monkeypatch.context() as m:
        m.setattr(migrations, "MIGRATIONS", ())
        db.init_db()
    conn = sqlite3.connect(path)
    conn.executescript("""
        INSERT INTO salespeople (id, nombre, email) VALUES (1, 'Juan', 'juan@test.local');
        INSERT INTO clients (id, razon_social, alias) VALUES (1, 'Tecnologia Rivera SL', 'Rivera'),
                                                             (2, 'Instituto San Lucas', 'San Lucas');
        INSERT INTO contacts (id, client_id, nombre) VALUES (1, 1, 'Marta Lopez'), (2, 2, 'Carlos Ruiz');
        INSERT INTO products (id, nombre, precio) VALUES (1, 'Portatil Luna 13', 790.0);
        INSERT INTO activities (id, datetime_iso, client_id, contact_id, activity_type_id, salesperson_id, comentario)
        VALUES (1, '2026-03-08T11:00:00.000', 1, 1, 1, 1, 'pasada con milisegundos'),
               (2, '2026-05-18T20:00:00', 1, NULL, 1, 1, 'pasada'),
               (3, '2026-12-01T10:00:00', 2, 2, 1, 1, 'futura'),
               (4, NULL, 1, NULL, 1, 1, 'sin fecha');
        INSERT INTO activity_products (activity_id, product_id, product_raw) VALUES (1, 1, 'Luna 13');
        INSERT INTO invoices (id, fecha, client_id) VALUES (1, '2026-01-10', 1);
        INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (1, 1, 8, 790, 6320.0);
    """)
    conn.commit()
    conn.close()
    return path


def _dump(path, tables):
    conn = sqlite3.connect(path)
    try:
        return {t: conn.execute(f"SELECT * FROM {t} ORDER BY rowid").fetchall() for t in tables}
    finally:
        conn.close()


def _query(path, sql, params=()):
    conn = sqlite3.connect(path)
    try:
        return conn.execute(sql, params).fetchall()
    finally:
        conn.close()


def _version(path):
    return _query(path, "PRAGMA user_version")[0][0]


def test_la_base_v0_empieza_sin_versionar(v0_db):
    assert _version(v0_db) == 0
    assert not _query(v0_db, "SELECT 1 FROM sqlite_master WHERE name = 'sales'")


def test_v0_a_la_ultima_conserva_los_datos(v0_db):
    before = _dump(v0_db, BUSINESS)

    db.init_db(now=NOW)

    assert _version(v0_db) == migrations.LATEST_VERSION == 6
    after = _dump(v0_db, BUSINESS)
    # Clientes y contactos ganan columnas de auditoría (NULL): sus datos de antes, intactos
    for table in BUSINESS:
        assert [row[:len(before[table][0])] for row in after[table]] == before[table], table
    assert _query(v0_db, "SELECT created_by_salesperson_id, created_at, updated_at FROM clients") == [
        (None, None, None), (None, None, None)]


def test_m001_estado_por_fecha_y_fechas_sin_milisegundos(v0_db):
    db.init_db(now=NOW)

    rows = _query(v0_db, "SELECT id, datetime_iso, status, updated_at, comentario FROM activities ORDER BY id")
    assert rows == [
        (1, "2026-03-08T11:00:00", "completed", None, "pasada con milisegundos"),
        (2, "2026-05-18T20:00:00", "completed", None, "pasada"),
        (3, "2026-12-01T10:00:00", "pending", None, "futura"),
        (4, None, "completed", None, "sin fecha"),
    ]
    assert _query(v0_db, "SELECT name FROM sqlite_master WHERE name = 'idx_activities_owner_status'")


def test_m001_el_estado_solo_admite_los_tres_valores(v0_db):
    db.init_db(now=NOW)
    conn = sqlite3.connect(v0_db)
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("UPDATE activities SET status = 'hecha' WHERE id = 1")
    conn.close()


def test_m003_ventas_y_vista_de_ingresos(v0_db):
    db.init_db(now=NOW)
    conn = sqlite3.connect(v0_db)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("""INSERT INTO sales (salesperson_id, client_id, product_id, quantity, amount_cents, sale_date)
                    VALUES (1, 1, 1, 5, 450000, '2026-09-30')""")
    conn.commit()

    lines = conn.execute("SELECT source, client_id, salesperson_id, product_id, amount_cents, day "
                         "FROM revenue_lines ORDER BY source").fetchall()
    assert lines == [("invoice", 1, None, 1, 632000, "2026-01-10"), ("sale", 1, 1, 1, 450000, "2026-09-30")]
    # Ni importe cero ni una venta sin producto ni concepto
    for sql in ("INSERT INTO sales (salesperson_id, client_id, product_id, amount_cents, sale_date) "
                "VALUES (1, 1, 1, 0, '2026-09-30')",
                "INSERT INTO sales (salesperson_id, client_id, amount_cents, sale_date, concept) "
                "VALUES (1, 1, 100, '2026-09-30', '  ')"):
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(sql)
    conn.close()
    # Las facturas no se han tocado
    assert _query(v0_db, "SELECT total FROM invoice_lines") == [(6320.0,)]


def test_m004_tabla_de_borradores(v0_db):
    db.init_db(now=NOW)
    columns = {r[1] for r in _query(v0_db, "PRAGMA table_info(action_drafts)")}
    assert {"public_id", "salesperson_id", "action_type", "status", "revision", "source", "source_text",
            "interpretation", "payload", "issues", "result", "created_at", "updated_at", "expires_at"} <= columns
    assert _query(v0_db, "SELECT name FROM sqlite_master WHERE name = 'idx_action_drafts_owner'")


def test_m005_los_datos_existentes_son_coherentes_y_los_triggers_bloquean(v0_db):
    db.init_db(now=NOW)
    # Ninguna actividad existente tiene un contacto de otro cliente
    assert _query(v0_db, """SELECT COUNT(*) FROM activities a JOIN contacts c ON c.id = a.contact_id
                            WHERE c.client_id != a.client_id""") == [(0,)]
    conn = sqlite3.connect(v0_db)
    statements = [
        "INSERT INTO activities (client_id, contact_id, activity_type_id, salesperson_id) VALUES (1, 2, 1, 1)",
        "UPDATE activities SET contact_id = 2 WHERE id = 1",
        "UPDATE activities SET client_id = 2 WHERE id = 1",
        "INSERT INTO sales (salesperson_id, client_id, contact_id, product_id, amount_cents, sale_date) "
        "VALUES (1, 1, 2, 1, 100, '2026-09-30')",
    ]
    for sql in statements:
        with pytest.raises(sqlite3.IntegrityError, match="contact_client_mismatch"):
            conn.execute(sql)
    # Lo coherente sigue pasando
    conn.execute("INSERT INTO activities (client_id, contact_id, activity_type_id, salesperson_id) VALUES (2, 2, 1, 1)")
    conn.close()


def test_segunda_inicializacion_no_hace_nada(v0_db):
    db.init_db(now=NOW)
    before = _dump(v0_db, BUSINESS + ("activities",))
    schema = _query(v0_db, "SELECT name, sql FROM sqlite_master ORDER BY name")

    db.init_db(now=datetime(2027, 6, 1))   # otra "hora": no se vuelve a calcular ningún estado

    assert _version(v0_db) == 6
    assert _dump(v0_db, BUSINESS + ("activities",)) == before
    assert _query(v0_db, "SELECT name, sql FROM sqlite_master ORDER BY name") == schema


def test_copia_de_seguridad_una_sola_vez_antes_de_migrar(v0_db):
    backup = migrations.backup_path(v0_db, 0)
    assert not backup.exists()

    db.init_db(now=NOW)

    assert backup.exists()
    # La copia es la base v0 tal cual (versión 0, sin tablas nuevas, con los datos)
    assert _version(backup) == 0
    assert not _query(backup, "SELECT 1 FROM sqlite_master WHERE name = 'sales'")
    assert _query(backup, "SELECT COUNT(*) FROM activities") == [(4,)]
    mtime = backup.stat().st_mtime_ns

    db.init_db(now=NOW)

    assert backup.stat().st_mtime_ns == mtime
    assert sorted(p.name for p in v0_db.parent.iterdir() if ".bak-" in p.name) == [backup.name]


def test_una_base_nueva_no_crea_copia(isolated_backend):
    # La SQLite de cada test se crea nueva: sin copia de seguridad
    assert _version(isolated_backend) == migrations.LATEST_VERSION
    assert not [p for p in isolated_backend.parent.iterdir() if ".bak-" in p.name]
    assert not migrations.needs_backup(isolated_backend)
    assert not migrations.needs_backup(isolated_backend.parent / "no-existe.db")


def test_una_migracion_fallida_no_avanza_la_version_ni_deja_ddl(v0_db, monkeypatch):
    def boom(conn, now):
        conn.execute("CREATE TABLE a_medias (id INTEGER)")
        raise RuntimeError("fallo simulado")

    monkeypatch.setattr(migrations, "MIGRATIONS", migrations.MIGRATIONS[:2] + ((3, "m003_boom", boom),))
    with pytest.raises(RuntimeError, match="fallo simulado"):
        db.init_db(now=NOW)

    assert _version(v0_db) == 2                 # m001 y m002 sí, m003 no
    assert not _query(v0_db, "SELECT 1 FROM sqlite_master WHERE name = 'a_medias'")
    assert {r[1] for r in _query(v0_db, "PRAGMA table_info(activities)")} >= {"status", "updated_at"}

    monkeypatch.undo()
    monkeypatch.setattr(db, "DB_PATH", v0_db)
    db.init_db(now=NOW)                         # al reintentar, continúa desde la versión 2
    assert _version(v0_db) == 6


def test_los_tests_nunca_usan_la_base_real(isolated_backend):
    from conftest import REAL_DB

    assert isolated_backend.resolve() != REAL_DB.resolve()
    assert db.DB_PATH == isolated_backend


def test_m006_borradores_de_productos_conservando_los_existentes(v0_db, monkeypatch):
    # Base en v5 con un borrador abierto (como la BD real antes de I.8)
    with monkeypatch.context() as m:
        m.setattr(migrations, "MIGRATIONS", migrations.MIGRATIONS[:5])
        db.init_db(now=NOW)
    conn = sqlite3.connect(v0_db)
    conn.execute("""INSERT INTO action_drafts (public_id, salesperson_id, action_type, revision, source, source_text,
                                               interpretation, payload, issues, expires_at)
                    VALUES ('abc', 1, 'create_sale', 3, 'voice', 'vendí', '{}', '{}', '[]', '2026-10-01T10:00:00')""")
    conn.commit()
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("""INSERT INTO action_drafts (public_id, salesperson_id, action_type, source, source_text,
                        interpretation, payload, issues, expires_at)
                        VALUES ('x', 1, 'create_product', 'text', 't', '{}', '{}', '[]', '2026-10-01')""")
    conn.close()
    products_before = _query(v0_db, "PRAGMA table_info(products)")

    db.init_db(now=NOW)

    assert _version(v0_db) == 6
    assert _query(v0_db, "SELECT public_id, action_type, revision, source FROM action_drafts") == [
        ("abc", "create_sale", 3, "voice")]
    assert _query(v0_db, "SELECT name FROM sqlite_master WHERE name = 'idx_action_drafts_owner'")
    assert _query(v0_db, "PRAGMA table_info(products)") == products_before      # el catálogo no cambia: sin stock
    conn = sqlite3.connect(v0_db)
    for kind in ("create_product", "update_product"):
        conn.execute("""INSERT INTO action_drafts (public_id, salesperson_id, action_type, source, source_text,
                        interpretation, payload, issues, expires_at)
                        VALUES (?, 1, ?, 'text', 't', '{}', '{}', '[]', '2026-10-01')""", (kind, kind))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("""INSERT INTO action_drafts (public_id, salesperson_id, action_type, source, source_text,
                        interpretation, payload, issues, expires_at)
                        VALUES ('y', 1, 'adjust_stock', 'text', 't', '{}', '{}', '[]', '2026-10-01')""")
    conn.close()
