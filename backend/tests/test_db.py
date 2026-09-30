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
