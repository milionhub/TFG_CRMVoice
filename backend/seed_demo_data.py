"""
Carga un catálogo de DEMOSTRACIÓN en backend/crm.db.

Todos los datos son ficticios (empresas "Demo", personas y productos inventados)
y se limitan a lo que CRMVoice usa: clientes con alias, contactos, productos con
alias para el reconocimiento por voz y unas facturas para el chat de facturación.
No crea usuarios (regístrate desde la app), ni actividades, ni embeddings.
Los tipos de actividad no están aquí: son datos de referencia y los crea db.init_db().

Uso (desde backend/, con el venv activo):
    python seed_demo_data.py

Es idempotente y seguro: si la base de datos ya tiene datos de catálogo,
no modifica nada.
"""
import sqlite3
import sys

from db import get_connection, init_db, DB_PATH

# alias: palabra que se reconoce por voz ("... de Nebula ...")
CLIENTS = [
    ("Nebula Logística Demo S.L.", "Nebula"),
    ("Orión Consultoría Demo S.L.", "Orion"),
    ("Ayuntamiento de Villademo", "Villademo"),
    ("Instituto Lumen Demo", "Lumen"),
    ("Clínica Aurora Demo", "Aurora"),
]

# (alias del cliente, nombre del contacto)
CONTACTS = [
    ("Nebula", "Nora Quintana"),
    ("Nebula", "Hugo Balmes"),
    ("Orion", "Alma Ferrer"),
    ("Villademo", "Bruno Salvat"),
    ("Lumen", "Irene Vidal"),
    ("Lumen", "Teo Arranz"),
    ("Aurora", "Vera Campillo"),
]

# (nombre, precio, alias para el reconocimiento por voz)
PRODUCTS = [
    ("Portátil Aster 14", 849.0, ["aster 14", "portatil aster"]),
    ("Portátil Orbe 16", 1249.0, ["orbe 16", "portatil orbe"]),
    ("Monitor Vela 24", 189.0, ["vela 24", "monitor vela"]),
    ("Monitor Cumbre 32", 399.0, ["cumbre 32", "monitor cumbre"]),
    ("Auriculares Eco Pro", 79.0, ["auriculares eco"]),
    ("Licencia Suite Demo", 120.0, ["licencia suite"]),
]

# (fecha, alias del cliente, [(producto, cantidad), ...])
INVOICES = [
    ("2026-05-06", "Nebula", [("Portátil Aster 14", 5), ("Monitor Vela 24", 5)]),
    ("2026-06-17", "Nebula", [("Licencia Suite Demo", 12)]),
    ("2026-05-20", "Orion", [("Portátil Orbe 16", 3), ("Monitor Cumbre 32", 3)]),
    ("2026-04-28", "Villademo", [("Portátil Aster 14", 10), ("Auriculares Eco Pro", 10)]),
    ("2026-06-09", "Villademo", [("Monitor Vela 24", 8)]),
    ("2026-05-13", "Lumen", [("Portátil Aster 14", 15)]),
    ("2026-06-24", "Lumen", [("Auriculares Eco Pro", 20), ("Licencia Suite Demo", 15)]),
    ("2026-06-02", "Aurora", [("Auriculares Eco Pro", 2)]),
]

# Tablas de catálogo que carga este script (activity_types es de referencia)
CATALOG_TABLES = ("clients", "contacts", "products", "product_aliases", "invoices", "invoice_lines")


def seed() -> int:
    """Devuelve 0 si ha cargado los datos o no hacía falta; 1 si no ha podido."""
    try:
        init_db()
        conn = get_connection()
    except sqlite3.Error as e:
        print(f"No se puede preparar la base de datos {DB_PATH}: {e}")
        return 1

    try:
        cur = conn.cursor()

        filled = [t for t in CATALOG_TABLES if cur.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] > 0]

        if "clients" in filled:
            print(f"{DB_PATH} ya tiene datos de catálogo: no se ha cargado nada.")
            return 0

        if filled:
            print(
                f"{DB_PATH} está parcialmente poblada (con datos en: {', '.join(filled)}, pero sin clientes).\n"
                "No se ha cargado nada para no mezclar datos. Usa una base de datos nueva "
                "(renombra o elimina crm.db) y vuelve a ejecutar el script."
            )
            return 1

        client_ids = {}
        for razon_social, alias in CLIENTS:
            cur.execute("INSERT INTO clients (razon_social, alias) VALUES (?, ?)", (razon_social, alias))
            client_ids[alias] = cur.lastrowid

        for client_alias, nombre in CONTACTS:
            cur.execute(
                "INSERT INTO contacts (client_id, nombre) VALUES (?, ?)",
                (client_ids[client_alias], nombre)
            )

        products = {}
        for nombre, precio, aliases in PRODUCTS:
            cur.execute("INSERT INTO products (nombre, precio) VALUES (?, ?)", (nombre, precio))
            product_id = cur.lastrowid
            products[nombre] = (product_id, precio)
            cur.executemany(
                "INSERT INTO product_aliases (product_id, alias) VALUES (?, ?)",
                [(product_id, alias) for alias in aliases]
            )

        for fecha, client_alias, lines in INVOICES:
            cur.execute(
                "INSERT INTO invoices (fecha, client_id) VALUES (?, ?)",
                (fecha, client_ids[client_alias])
            )
            invoice_id = cur.lastrowid
            for product_name, cantidad in lines:
                product_id, precio = products[product_name]
                cur.execute(
                    "INSERT INTO invoice_lines (invoice_id, product_id, cantidad, precio, total) VALUES (?, ?, ?, ?, ?)",
                    (invoice_id, product_id, cantidad, precio, cantidad * precio)
                )

        conn.commit()

    except sqlite3.Error as e:
        conn.rollback()
        print(f"No se ha cargado nada: la base de datos {DB_PATH} no es compatible ({e}).")
        return 1

    finally:
        conn.close()

    print(
        f"Catálogo de demostración cargado en {DB_PATH}: "
        f"{len(CLIENTS)} clientes, {len(CONTACTS)} contactos, "
        f"{len(PRODUCTS)} productos, {len(INVOICES)} facturas."
    )
    return 0


if __name__ == "__main__":
    sys.exit(seed())
