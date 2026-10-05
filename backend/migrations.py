"""
Migraciones versionadas de la SQLite (H.2), con PRAGMA user_version.

init_db() crea primero el esquema base con CREATE ... IF NOT EXISTS (la
"versión 0", igual que antes de H.2) y después llama a apply_migrations(),
que aplica en orden las migraciones pendientes:

- cada una corre en su propia transacción (BEGIN IMMEDIATE) y deja
  user_version = N en ESA transacción: si falla, ni su DDL ni la versión
  quedan aplicados (SQLite hace transaccional el DDL);
- una base ya migrada no hace nada (idempotente por user_version);
- todas son aditivas: ninguna borra tablas, columnas ni datos.

Copia de seguridad: antes de migrar una base de datos que YA EXISTÍA en
disco con datos (no una recién creada, como las de los tests), se copia el
fichero a "<db>.bak-v<versión anterior>" una sola vez. Esa copia es el
rollback: no hay migraciones "down".
"""
import logging
import shutil
import sqlite3
from datetime import datetime
from pathlib import Path

logger = logging.getLogger("crmvoice")


def _m001_activity_status(conn: sqlite3.Connection, now: datetime) -> None:
    """Activity V2: estado, updated_at y fechas sin milisegundos."""
    conn.execute("""
        ALTER TABLE activities ADD COLUMN status TEXT NOT NULL DEFAULT 'completed'
        CHECK (status IN ('pending', 'completed', 'cancelled'))
    """)
    conn.execute("ALTER TABLE activities ADD COLUMN updated_at TEXT")
    # "2026-03-08T11:00:00.000" -> "2026-03-08T11:00:00" (misma hora, sin milisegundos)
    conn.execute("""
        UPDATE activities SET datetime_iso = substr(datetime_iso, 1, 19)
        WHERE length(datetime_iso) > 19 AND datetime_iso GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].*'
    """)
    # Futuras -> pendientes; el resto (y las que no tienen fecha) -> completadas
    conn.execute("""
        UPDATE activities SET status = CASE WHEN datetime_iso > ? THEN 'pending' ELSE 'completed' END
    """, (now.strftime("%Y-%m-%dT%H:%M:%S"),))
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_activities_owner_status
        ON activities(salesperson_id, status, datetime_iso)
    """)


def _m002_audit_columns(conn: sqlite3.Connection, now: datetime) -> None:
    """Auditoría de clientes y contactos (compartidos): quién y cuándo. NO filtra visibilidad."""
    for table in ("clients", "contacts"):
        conn.execute(f"""
            ALTER TABLE {table} ADD COLUMN created_by_salesperson_id INTEGER
            REFERENCES salespeople(id) ON DELETE SET NULL
        """)
        conn.execute(f"ALTER TABLE {table} ADD COLUMN created_at TEXT")
        conn.execute(f"ALTER TABLE {table} ADD COLUMN updated_at TEXT")


def _m003_sales(conn: sqlite3.Connection, now: datetime) -> None:
    """Ventas: una fila = una línea de venta, importe total en céntimos (sin REAL)."""
    conn.execute("""
        CREATE TABLE sales (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            salesperson_id  INTEGER NOT NULL REFERENCES salespeople(id),
            client_id       INTEGER NOT NULL REFERENCES clients(id),
            contact_id      INTEGER REFERENCES contacts(id),
            product_id      INTEGER REFERENCES products(id),
            quantity        INTEGER CHECK (quantity IS NULL OR quantity > 0),
            amount_cents    INTEGER NOT NULL CHECK (amount_cents > 0),
            sale_date       TEXT NOT NULL,
            concept         TEXT,
            notes           TEXT,
            created_at      TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at      TEXT,
            CHECK (product_id IS NOT NULL OR (concept IS NOT NULL AND length(trim(concept)) > 0))
        )
    """)
    conn.execute("CREATE INDEX idx_sales_client ON sales(client_id, sale_date)")
    conn.execute("CREATE INDEX idx_sales_salesperson ON sales(salesperson_id, sale_date)")
    # Solo lectura: facturas históricas (globales, sin comercial) + ventas nuevas, con su origen
    conn.execute("""
        CREATE VIEW revenue_lines AS
            SELECT 'invoice' AS source, l.id AS source_id, i.client_id, NULL AS salesperson_id,
                   l.product_id, l.cantidad AS quantity,
                   CAST(round(l.total * 100) AS INTEGER) AS amount_cents, i.fecha AS day
            FROM invoice_lines l JOIN invoices i ON i.id = l.invoice_id
            UNION ALL
            SELECT 'sale', s.id, s.client_id, s.salesperson_id,
                   s.product_id, s.quantity, s.amount_cents, s.sale_date
            FROM sales s
    """)


def _m004_action_drafts(conn: sqlite3.Connection, now: datetime) -> None:
    """Borradores del Action Engine: del comercial, con revisión y caducidad."""
    conn.execute("""
        CREATE TABLE action_drafts (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            public_id       TEXT NOT NULL UNIQUE,
            salesperson_id  INTEGER NOT NULL REFERENCES salespeople(id) ON DELETE CASCADE,
            action_type     TEXT NOT NULL CHECK (action_type IN
                                ('create_activity', 'create_client', 'create_contact', 'create_sale')),
            status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'executed', 'cancelled')),
            revision        INTEGER NOT NULL DEFAULT 1,
            source          TEXT NOT NULL CHECK (source IN ('voice', 'text', 'chat')),
            source_text     TEXT NOT NULL CHECK (length(source_text) <= 2000),
            interpretation  TEXT NOT NULL,
            payload         TEXT NOT NULL,
            issues          TEXT NOT NULL,
            result          TEXT,
            created_at      TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
            expires_at      TEXT NOT NULL
        )
    """)
    conn.execute("CREATE INDEX idx_action_drafts_owner ON action_drafts(salesperson_id, status)")


def _m005_consistency_triggers(conn: sqlite3.Connection, now: datetime) -> None:
    """
    Defensa en profundidad: un contacto solo puede ir con SU cliente.
    La validación principal está en los servicios de escritura; esto solo
    impide que una escritura que se los salte deje datos incoherentes.
    """
    mismatch = ("NEW.contact_id IS NOT NULL AND NOT EXISTS ("
                "SELECT 1 FROM contacts c WHERE c.id = NEW.contact_id AND c.client_id IS NEW.client_id)")
    for table in ("activities", "sales"):
        for event in ("INSERT", "UPDATE OF contact_id, client_id"):
            name = f"trg_{table}_contact_client_{event.split()[0].lower()}"
            conn.execute(f"""
                CREATE TRIGGER {name} BEFORE {event} ON {table}
                WHEN {mismatch}
                BEGIN SELECT RAISE(ABORT, 'contact_client_mismatch'); END
            """)


MIGRATIONS = (
    (1, "m001_activity_status", _m001_activity_status),
    (2, "m002_audit_columns", _m002_audit_columns),
    (3, "m003_sales", _m003_sales),
    (4, "m004_action_drafts", _m004_action_drafts),
    (5, "m005_consistency_triggers", _m005_consistency_triggers),
)

LATEST_VERSION = MIGRATIONS[-1][0]

# Mensaje estable del trigger (los servicios lo traducen a un error de validación)
CONTACT_CLIENT_MISMATCH = "contact_client_mismatch"


def user_version(conn: sqlite3.Connection) -> int:
    return conn.execute("PRAGMA user_version").fetchone()[0]


def backup_path(db_path: Path, version: int) -> Path:
    return db_path.with_name(f"{db_path.name}.bak-v{version}")


def apply_migrations(db_path: Path, *, backup: bool, now: datetime | None = None) -> int:
    """
    Aplica las migraciones pendientes y devuelve la versión final.
    backup=True solo para una base que ya existía con datos antes de init_db().
    """
    now = (now or datetime.now()).replace(microsecond=0)
    conn = sqlite3.connect(db_path, isolation_level=None)  # transacciones explícitas
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        current = user_version(conn)
        pending = [m for m in MIGRATIONS if m[0] > current]
        if not pending:
            return current

        if backup:
            target = backup_path(Path(db_path), current)
            if not target.exists():
                # La copia se hace con la conexión de SQLite (consistente aunque haya -journal)
                with sqlite3.connect(target) as copy:
                    conn.backup(copy)
                copy.close()
                logger.info("Copia de seguridad de la BD antes de migrar: %s", target.name)

        for version, name, migrate in pending:
            conn.execute("BEGIN IMMEDIATE")
            try:
                migrate(conn, now)
                conn.execute(f"PRAGMA user_version = {int(version)}")
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                logger.exception("La migración %s ha fallado: la BD sigue en la versión %s", name, version - 1)
                raise
            logger.info("Migración aplicada: %s", name)
        return pending[-1][0]
    finally:
        conn.close()


def needs_backup(db_path: Path) -> bool:
    """¿Es una base existente con datos (no un fichero nuevo o vacío)? Se mira ANTES de init_db()."""
    try:
        if not db_path.exists() or db_path.stat().st_size == 0:
            return False
        conn = sqlite3.connect(f"file:{db_path.as_posix()}?mode=ro", uri=True)
        try:
            has_tables = conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'activities'").fetchone()
            return bool(has_tables) and user_version(conn) < LATEST_VERSION
        finally:
            conn.close()
    except sqlite3.Error:
        return False
