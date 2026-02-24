import sqlite3
from auth_utils import hash_password
from datetime import datetime

DB_PATH = "crm.db"

users = [
    ("Juan Marín", "juan.marin@empresa.es", "1234"),
    ("Laura Sánchez", "laura.sanchez@empresa.es", "1234"),
    ("Carlos Pérez", "carlos.perez@empresa.es", "1234"),
    ("Ana Torres", "ana.torres@empresa.es", "1234"),
    ("David López", "david.lopez@empresa.es", "1234"),
]

conn = sqlite3.connect(DB_PATH)
cursor = conn.cursor()

for nombre, email, password in users:
    password_hash = hash_password(password)

    cursor.execute("""
        INSERT INTO salespeople (nombre, email, password_hash, created_at)
        VALUES (?, ?, ?, ?)
    """, (nombre, email, password_hash, datetime.now()))

conn.commit()
conn.close()

print("Usuarios creados correctamente 🚀")