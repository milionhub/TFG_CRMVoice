"""
Actividades del comercial: listado con filtros, alta (embedding, duplicados,
productos), edición, borrado y la búsqueda semántica de /semantic-search.

Todas las consultas se limitan al comercial (salesperson_id) recibido.
Sin FastAPI: los routers traducen ActivityNotFound (404), InvalidActivity
(422) y DuplicateActivity (409) a HTTP.

Las conexiones usan db.connection(): commit si todo va bien, rollback ante
cualquier excepción y cierre siempre.
"""
import json
import logging
import sqlite3

import numpy as np

from db import connection
from services.openai_service import generate_embedding

logger = logging.getLogger("crmvoice")


class ActivityNotFound(Exception):
    """La actividad no existe o no pertenece al comercial."""


class InvalidActivity(ValueError):
    """Datos de la actividad incompletos o que referencian entidades inexistentes."""


class DuplicateActivity(Exception):
    """Ya existe una actividad prácticamente idéntica."""

    def __init__(self, similarity: float):
        super().__init__("Actividad duplicada detectada")
        self.similarity = similarity


MISSING_REFERENCE_MESSAGE = "Cliente, contacto, tipo de actividad o producto inexistente"

# PUT /activities/{id} es una sustitución completa (B7): estos campos deben
# venir siempre (contact_id y activity_type_id pueden ser null explícito).
# El comentario es opcional: si no se envía se conserva (el calendario no lo edita).
UPDATE_REQUIRED_FIELDS = ("fecha", "client_id", "contact_id", "activity_type_id", "products")


def _is_missing_reference(error: sqlite3.IntegrityError) -> bool:
    return "FOREIGN KEY constraint failed" in str(error)


def list_activities(
    salesperson_id: int,
    client_id: int | None = None,
    action_id: int | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
) -> dict:
    base_query = """
        SELECT
            a.id,
            a.datetime_iso,
            a.client_id,
            a.contact_id,
            a.activity_type_id,
            a.comentario,
            a.resolution_status,
            c.razon_social AS cliente,
            at.accion AS accion,
            ct.nombre AS contacto
        FROM activities a
        LEFT JOIN clients c ON a.client_id = c.id
        LEFT JOIN activity_types at ON a.activity_type_id = at.id
        LEFT JOIN contacts ct ON a.contact_id = ct.id
    """

    conditions = ["a.salesperson_id = ?"]
    params = [salesperson_id]

    if client_id:
        conditions.append("a.client_id = ?")
        params.append(client_id)

    if action_id:
        conditions.append("a.activity_type_id = ?")
        params.append(action_id)

    if date_from:
        conditions.append("a.datetime_iso >= ?")
        params.append(date_from + "T00:00:00")

    if date_to:
        conditions.append("a.datetime_iso <= ?")
        params.append(date_to + "T23:59:59")

    if conditions:
        base_query += " WHERE " + " AND ".join(conditions)

    base_query += " ORDER BY a.datetime_iso DESC"

    activities = []

    with connection() as conn:
        cursor = conn.cursor()
        cursor.execute(base_query, params)
        rows = cursor.fetchall()

        for r in rows:

            # 🔹 Obtener productos de la actividad
            cursor.execute("""
                SELECT product_id, product_raw
                FROM activity_products
                WHERE activity_id = ?
            """, (r["id"],))

            product_rows = cursor.fetchall()

            # product_id es necesario para que la edición conserve los productos
            products = [
                {
                    "product_id": p["product_id"],
                    "product_raw": p["product_raw"]
                }
                for p in product_rows
            ]

            activities.append({
                "id": r["id"],
                "fecha": r["datetime_iso"],

                # 🔹 IDs reales
                "client_id": r["client_id"],
                "contact_id": r["contact_id"],
                "activity_type_id": r["activity_type_id"],

                # 🔹 Datos visibles
                "cliente": r["cliente"],
                "contacto": r["contacto"],
                "accion": r["accion"],
                "comentario": r["comentario"],
                "resolution_status": r["resolution_status"],

                "products": products
            })

    return {
        "count": len(activities),
        "activities": activities
    }


def create_activity(data: dict, salesperson_id: int) -> dict:
    # -------------------------------
    # 1️⃣ Validación (antes de llamar a OpenAI o escribir nada)
    # -------------------------------
    client_id = data.get("cliente_id")
    contact_id = data.get("contacto_id")
    activity_type_id = data.get("activity_type_id")

    if not client_id:
        raise InvalidActivity("Cliente obligatorio")

    if not (contact_id or activity_type_id):
        raise InvalidActivity("Debe existir contacto o tipo de actividad")

    products = data.get("products_detected") or []

    if not isinstance(products, list) or any(
        not isinstance(p, dict) or p.get("product_id") is None for p in products
    ):
        raise InvalidActivity("Cada producto debe indicar su product_id")

    # -------------------------------
    # 2️⃣ Generar embedding
    # -------------------------------
    embedding_text = f"""
    Cliente: {data.get("cliente_detectado")}
    Acción: {data.get("accion_detectada")}
    Comentario: {data.get("texto")}
    """

    try:
        vector = generate_embedding(embedding_text)
    except Exception:
        logger.exception("Error generando el embedding de la actividad")
        vector = None

    # -------------------------------
    # 3️⃣ Control duplicados
    # -------------------------------
    if vector:
        from services.openai_service import is_duplicate_activity

        is_dup, similarity_score = is_duplicate_activity(
            vector,
            client_id,
            activity_type_id,
            data.get("fecha_detectada")
        )

        if is_dup:
            raise DuplicateActivity(similarity_score)


    fecha = data.get("fecha_detectada")

    if fecha:
        datetime_iso = fecha
    else:
        from datetime import datetime
        datetime_iso = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")

    try:
        with connection() as conn:
            cursor = conn.cursor()

            # -------------------------------
            # 4️⃣ Insert activity
            # -------------------------------
            cursor.execute("""
                INSERT INTO activities (
                    datetime_iso,
                    client_id,
                    contact_id,
                    activity_type_id,
                    comentario,
                    transcripcion,
                    cliente_raw,
                    contacto_raw,
                    accion_raw,
                    resolution_status,
                    resolution_confidence,
                    salesperson_id
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                datetime_iso,
                client_id,
                contact_id,
                activity_type_id,
                data.get("texto"),
                data.get("texto"),
                data.get("cliente_detectado"),
                data.get("contacto_detectado"),
                data.get("accion_detectada"),
                data.get("resolution_status"),
                data.get("overall_confidence"),
                salesperson_id,
            ))

            activity_id = cursor.lastrowid

            # -------------------------------
            # 5️⃣ Guardar productos
            # -------------------------------
            for p in products:
                cursor.execute("""
                    INSERT INTO activity_products (
                        activity_id,
                        product_id,
                        product_raw,
                        confidence_score
                    )
                    VALUES (?, ?, ?, ?)
                """, (
                    activity_id,
                    p["product_id"],
                    p.get("product_raw"),
                    p.get("confidence")
                ))

            # -------------------------------
            # 6️⃣ Guardar embedding
            # -------------------------------
            if vector:
                cursor.execute("""
                    INSERT INTO activity_embeddings (
                        activity_id,
                        embedding_vector,
                        embedding_model,
                        content_type
                    )
                    VALUES (?, ?, ?, ?)
                """, (
                    activity_id,
                    json.dumps(vector),
                    "text-embedding-3-small",
                    "activity_full"
                ))

    except sqlite3.IntegrityError as error:
        if _is_missing_reference(error):
            raise InvalidActivity(MISSING_REFERENCE_MESSAGE) from error
        raise

    return {
        "success": True,
        "activity_id": activity_id
    }


def semantic_search(query_text: str, salesperson_id: int) -> list[dict]:
    """
    Búsqueda de /semantic-search: las 3 actividades del comercial más
    parecidas a la consulta. (La del chat es services.semantic_search_service.)
    """

    # 1️⃣ Generar embedding del query
    query_vector = generate_embedding(query_text)
    query_vector = np.array(query_vector)

    # 2️⃣ Obtener todos los embeddings almacenados
    with connection() as conn:
        rows = conn.execute("""
            SELECT ae.activity_id, ae.embedding_vector, a.datetime_iso, a.cliente_raw, a.comentario
            FROM activity_embeddings ae
            JOIN activities a ON a.id = ae.activity_id
            WHERE a.salesperson_id = ?
        """, (salesperson_id,)).fetchall()

    results = []

    for row in rows:
        activity_id = row["activity_id"]
        stored_vector = np.array(json.loads(row["embedding_vector"]))

        # 3️⃣ Calcular similitud coseno
        similarity = np.dot(query_vector, stored_vector) / (
            np.linalg.norm(query_vector) * np.linalg.norm(stored_vector)
        )

        results.append({
            "id": activity_id,
            "fecha": row["datetime_iso"],
            "cliente": row["cliente_raw"],
            "comentario": row["comentario"],
            "score_similitud": float(similarity)
        })

    # 4️⃣ Ordenar por similitud descendente
    results = sorted(results, key=lambda x: x["score_similitud"], reverse=True)

    # 5️⃣ Devolver top 3
    return results[:3]


def delete_activity(activity_id: int, salesperson_id: int) -> None:
    """Borra la actividad del comercial con sus productos y embedding."""

    # ActivityNotFound dentro del bloque -> rollback (no se confirma nada)
    with connection() as conn:
        cursor = conn.cursor()

        # 🔹 Comprobar propiedad antes de tocar ningún dato relacionado
        cursor.execute("""
            SELECT id FROM activities
            WHERE id = ? AND salesperson_id = ?
        """, (activity_id, salesperson_id))

        if cursor.fetchone() is None:
            raise ActivityNotFound()

        cursor.execute("DELETE FROM activity_products WHERE activity_id = ?", (activity_id,))
        cursor.execute("DELETE FROM activity_embeddings WHERE activity_id = ?", (activity_id,))
        cursor.execute("""
            DELETE FROM activities
            WHERE id = ?
            AND salesperson_id = ?
        """, (activity_id, salesperson_id))

        # Solo confirmamos si realmente se ha eliminado la actividad
        if cursor.rowcount != 1:
            raise ActivityNotFound()


def _validate_update(data: dict) -> None:
    """PUT = sustitución completa (B7): un payload incompleto no pone campos a NULL."""
    missing = [field for field in UPDATE_REQUIRED_FIELDS if field not in data]

    if missing:
        raise InvalidActivity("Faltan campos obligatorios: " + ", ".join(missing))

    if not data.get("fecha"):
        raise InvalidActivity("Fecha obligatoria")

    if not data.get("client_id"):
        raise InvalidActivity("Cliente obligatorio")

    products = data.get("products")

    if not isinstance(products, list) or any(not isinstance(p, dict) for p in products):
        raise InvalidActivity("products debe ser una lista de productos")


def update_activity(activity_id: int, data: dict, salesperson_id: int) -> dict:
    """Sustitución completa de la actividad del comercial (B7) y de sus productos."""

    with connection() as conn:
        cursor = conn.cursor()

        # 🔹 Comprobar propiedad y obtener comentario actual
        # (antes de validar, borrar/insertar productos o actualizar nada)
        cursor.execute("""
            SELECT comentario FROM activities
            WHERE id = ? AND salesperson_id = ?
        """, (activity_id, salesperson_id))

        row = cursor.fetchone()

        if row is None:
            raise ActivityNotFound()

        _validate_update(data)

        comentario_actual = row["comentario"]

        comentario = data.get("comentario", comentario_actual)

        # 🔹 Si cambia el comentario, el embedding queda obsoleto.
        comentario_cambiado = comentario != comentario_actual

        if comentario_cambiado:

            cursor.execute("SELECT razon_social FROM clients WHERE id = ?", (data.get("client_id"),))
            client_row = cursor.fetchone()

            cursor.execute("SELECT accion FROM activity_types WHERE id = ?", (data.get("activity_type_id"),))
            type_row = cursor.fetchone()

            embedding_text = f"""
    Cliente: {client_row["razon_social"] if client_row else None}
    Acción: {type_row["accion"] if type_row else None}
    Comentario: {comentario}
    """

    # Se genera ANTES de escribir nada (llamada de red fuera de la transacción)
    new_vector = None

    if comentario_cambiado:
        try:
            new_vector = generate_embedding(embedding_text)
        except Exception:
            logger.exception("Error regenerando embedding de la actividad %s", activity_id)
            new_vector = None

    try:
        with connection() as conn:
            cursor = conn.cursor()

            # 🔹 Update actividad
            cursor.execute("""
                UPDATE activities
                SET datetime_iso = ?,
                    client_id = ?,
                    contact_id = ?,
                    activity_type_id = ?,
                    comentario = ?
                WHERE id = ? AND salesperson_id = ?
            """, (
                data.get("fecha"),
                data.get("client_id"),
                data.get("contact_id"),
                data.get("activity_type_id"),
                comentario,
                activity_id,
                salesperson_id
            ))

            # Borrada entre la comprobación y la escritura: no se toca nada
            if cursor.rowcount != 1:
                raise ActivityNotFound()

            # 🔹 Borrar productos anteriores
            cursor.execute("""
                DELETE FROM activity_products
                WHERE activity_id = ?
            """, (activity_id,))

            # 🔹 Insertar nuevos productos
            for p in data.get("products"):

                # Se aceptan ambos formatos: {id, name} y {product_id, product_raw}
                product_id = p.get("id") if p.get("id") is not None else p.get("product_id")
                product_name = p.get("name") or p.get("product_raw")

                # 🔹 evitar crash si no hay id
                if product_id is None:
                    continue

                cursor.execute("""
                    INSERT INTO activity_products (
                        activity_id,
                        product_id,
                        product_raw,
                        confidence_score
                    )
                    VALUES (?, ?, ?, ?)
                """, (
                    activity_id,
                    product_id,
                    product_name,
                    1.0
                ))

            # 🔹 Mantener el embedding coherente con el comentario
            if comentario_cambiado:

                if new_vector:

                    cursor.execute("""
                        UPDATE activity_embeddings
                        SET embedding_vector = ?, created_at = datetime('now')
                        WHERE activity_id = ?
                    """, (json.dumps(new_vector), activity_id))

                    if cursor.rowcount == 0:
                        cursor.execute("""
                            INSERT INTO activity_embeddings (
                                activity_id,
                                embedding_vector,
                                embedding_model,
                                content_type
                            )
                            VALUES (?, ?, ?, ?)
                        """, (
                            activity_id,
                            json.dumps(new_vector),
                            "text-embedding-3-small",
                            "activity_full"
                        ))

                else:
                    # Si OpenAI falla, mejor sin embedding que con uno obsoleto
                    cursor.execute(
                        "DELETE FROM activity_embeddings WHERE activity_id = ?",
                        (activity_id,)
                    )

    except sqlite3.IntegrityError as error:
        if _is_missing_reference(error):
            raise InvalidActivity(MISSING_REFERENCE_MESSAGE) from error
        raise

    return {"success": True}
