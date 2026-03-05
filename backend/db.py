import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).parent / "crm.db"


def get_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON;")
    return conn


def init_db():
    conn = get_connection()
    cur = conn.cursor()

    # =====================================================
    # CATÁLOGOS
    # =====================================================

    cur.execute("""
        CREATE TABLE IF NOT EXISTS client_groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE
        );
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS clients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            razon_social TEXT NOT NULL,
            alias TEXT,
            group_id INTEGER,
            direccion TEXT,
            codigo_postal TEXT,
            provincia TEXT,
            pais TEXT,
            poblacion TEXT,
            cif TEXT,
            telefono TEXT,
            email TEXT,
            FOREIGN KEY (group_id) REFERENCES client_groups(id)
        );
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_clients_alias ON clients(alias);")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_clients_razon ON clients(razon_social);")

    cur.execute("""
        CREATE TABLE IF NOT EXISTS contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            client_id INTEGER NOT NULL,
            nombre TEXT NOT NULL,
            cargo TEXT,
            telefono TEXT,
            email TEXT,
            FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE
        );
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_contacts_client ON contacts(client_id);")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_contacts_nombre ON contacts(nombre);")

    cur.execute("""
        CREATE TABLE IF NOT EXISTS products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nombre TEXT NOT NULL UNIQUE,
            precio REAL
        );
    """)

    # NUEVA TABLA: alias de productos
    cur.execute("""
        CREATE TABLE IF NOT EXISTS product_aliases (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            product_id INTEGER NOT NULL,
            alias TEXT NOT NULL,
            FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
        );
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_product_alias ON product_aliases(alias);")

    cur.execute("""
        CREATE TABLE IF NOT EXISTS activity_types (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            accion TEXT NOT NULL UNIQUE
        );
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS salespeople (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nombre TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            google_id TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
    """)

    # =====================================================
    # ACTIVIDADES (SIN product_id)
    # =====================================================

    cur.execute("""
        CREATE TABLE IF NOT EXISTS activities (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT DEFAULT (datetime('now')),
            datetime_iso TEXT,

            client_id INTEGER,
            contact_id INTEGER,
            activity_type_id INTEGER,
            salesperson_id INTEGER,

            comentario TEXT,
            transcripcion TEXT,

            cliente_raw TEXT,
            contacto_raw TEXT,
            accion_raw TEXT,

            resolution_status TEXT,
            resolution_confidence INTEGER,

            FOREIGN KEY (client_id) REFERENCES clients(id),
            FOREIGN KEY (contact_id) REFERENCES contacts(id),
            FOREIGN KEY (activity_type_id) REFERENCES activity_types(id),
            FOREIGN KEY (salesperson_id) REFERENCES salespeople(id)
        );
    """)

    cur.execute("CREATE INDEX IF NOT EXISTS idx_activities_fecha ON activities(datetime_iso);")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_activities_client ON activities(client_id);")

    # =====================================================
    # NUEVA TABLA: RELACIÓN N:M ACTIVIDAD-PRODUCTO
    # =====================================================

    cur.execute("""
        CREATE TABLE IF NOT EXISTS activity_products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            activity_id INTEGER NOT NULL,
            product_id INTEGER NOT NULL,
            product_raw TEXT,
            confidence_score INTEGER,
            FOREIGN KEY (activity_id) REFERENCES activities(id) ON DELETE CASCADE,
            FOREIGN KEY (product_id) REFERENCES products(id)
        );
    """)
    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_activity_products_activity
        ON activity_products(activity_id);
    """)

    # =====================================================
    # EMBEDDINGS
    # =====================================================

    cur.execute("""
        CREATE TABLE IF NOT EXISTS activity_embeddings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            activity_id INTEGER NOT NULL,
            embedding_vector TEXT NOT NULL,
            embedding_model TEXT,
            content_type TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            FOREIGN KEY (activity_id) REFERENCES activities(id) ON DELETE CASCADE
        );
    """)
    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_embeddings_activity
        ON activity_embeddings(activity_id);
    """)

    # =====================================================
    # FACTURACIÓN
    # =====================================================

    cur.execute("""
        CREATE TABLE IF NOT EXISTS invoices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fecha TEXT,
            client_id INTEGER,
            contact_id INTEGER,
            salesperson_id INTEGER,
            detalle TEXT,
            FOREIGN KEY (client_id) REFERENCES clients(id),
            FOREIGN KEY (contact_id) REFERENCES contacts(id),
            FOREIGN KEY (salesperson_id) REFERENCES salespeople(id)
        );
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);")

    cur.execute("""
        CREATE TABLE IF NOT EXISTS invoice_lines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            invoice_id INTEGER NOT NULL,
            product_id INTEGER,
            cantidad REAL,
            precio REAL,
            total REAL,
            FOREIGN KEY (invoice_id) REFERENCES invoices(id) ON DELETE CASCADE,
            FOREIGN KEY (product_id) REFERENCES products(id)
        );
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_lines_invoice ON invoice_lines(invoice_id);")

    conn.commit()
    conn.close()
