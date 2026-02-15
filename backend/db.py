import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).parent / "crm.db"


def get_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row  # más cómodo para dicts
    conn.execute("PRAGMA foreign_keys = ON;")  # IMPORTANTÍSIMO en SQLite
    return conn


def init_db():
    conn = get_connection()
    cur = conn.cursor()

    # --- Catálogos / maestros ---
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
            email TEXT
        );
    """)

    # --- Actividades (núcleo) ---
    # OJO: guardamos también texto bruto por si la IA falla (trazabilidad)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS activities (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT DEFAULT (datetime('now')),
            fecha_iso TEXT,                 -- YYYY-MM-DD (normalizado)
            hora TEXT,                      -- opcional

            client_id INTEGER,
            contact_id INTEGER,
            product_id INTEGER,
            activity_type_id INTEGER,
            salesperson_id INTEGER,

            comentario TEXT,                -- “qué ha pasado”
            transcripcion TEXT,             -- texto real de Whisper

            cliente_raw TEXT,               -- lo que detectó el parser (por si no hay match)
            contacto_raw TEXT,
            producto_raw TEXT,
            accion_raw TEXT,

            FOREIGN KEY (client_id) REFERENCES clients(id),
            FOREIGN KEY (contact_id) REFERENCES contacts(id),
            FOREIGN KEY (product_id) REFERENCES products(id),
            FOREIGN KEY (activity_type_id) REFERENCES activity_types(id),
            FOREIGN KEY (salesperson_id) REFERENCES salespeople(id)
        );
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_activities_fecha ON activities(fecha_iso);")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_activities_client ON activities(client_id);")
    # Añadir resolution_status si no existe
    cur.execute("PRAGMA table_info(activities);")
    columns = [row["name"] for row in cur.fetchall()]

    if "resolution_status" not in columns:
        cur.execute("""
            ALTER TABLE activities
            ADD COLUMN resolution_status TEXT DEFAULT 'auto';
        """)


    # --- Facturación (para futuro, ya preparada) ---
    cur.execute("""
        CREATE TABLE IF NOT EXISTS invoices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,   -- num factura interno
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
