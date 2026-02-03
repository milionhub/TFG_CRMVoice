import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).parent / "crm.db"

def get_connection():
    return sqlite3.connect(DB_PATH)

def init_db():
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS activities (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            cliente TEXT,
            accion TEXT,
            fecha TEXT,
            comentario TEXT,
            transcripcion TEXT
        )
    """)

    conn.commit()
    conn.close()
