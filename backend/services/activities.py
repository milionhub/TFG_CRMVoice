"""
Lecturas de actividades del comercial (listado con filtros y la búsqueda
semántica de /semantic-search) y el embedding de cada actividad.

Las ESCRITURAS (alta, edición, estado, borrado) viven en
services/writes/activities.py desde H.2. Aquí queda ensure_embedding: el
embedding se genera DESPUÉS de guardar (red fuera de la transacción) y es
best-effort: si OpenAI falla, la actividad sigue guardada sin embedding.

Todas las consultas se limitan al comercial (salesperson_id) recibido.
"""
import json
import logging

import numpy as np

from db import connection
from services.openai_service import generate_embedding

logger = logging.getLogger("crmvoice")

EMBEDDING_MODEL = "text-embedding-3-small"


def list_activities(
    salesperson_id: int,
    client_id: int | None = None,
    action_id: int | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    status: str | None = None,
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
            a.status,
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

    if status:
        conditions.append("a.status = ?")
        params.append(status)

    if conditions:
        base_query += " WHERE " + " AND ".join(conditions)

    base_query += " ORDER BY a.datetime_iso DESC"

    activities = []

    with connection() as conn:
        cursor = conn.cursor()
        cursor.execute(base_query, params)
        rows = cursor.fetchall()

        for r in rows:

            # Productos de la actividad
            # Nombre oficial (name) además de lo dicho (product_raw): un producto
            # elegido a mano en un borrador no tiene product_raw, y uno
            # resuelto por aproximación tiene el texto mal transcrito (H4-01)
            cursor.execute("""
                SELECT ap.product_id, ap.product_raw, p.nombre AS name
                FROM activity_products ap
                LEFT JOIN products p ON p.id = ap.product_id
                WHERE ap.activity_id = ?
                ORDER BY ap.id
            """, (r["id"],))

            product_rows = cursor.fetchall()

            # product_id es necesario para que la edición conserve los productos
            products = [
                {
                    "product_id": p["product_id"],
                    "name": p["name"],
                    "product_raw": p["product_raw"]
                }
                for p in product_rows
            ]

            activities.append({
                "id": r["id"],
                "fecha": r["datetime_iso"],

                # IDs reales
                "client_id": r["client_id"],
                "contact_id": r["contact_id"],
                "activity_type_id": r["activity_type_id"],

                # Datos visibles
                "cliente": r["cliente"],
                "contacto": r["contacto"],
                "accion": r["accion"],
                "comentario": r["comentario"],
                "resolution_status": r["resolution_status"],
                "status": r["status"],

                "products": products
            })

    return {
        "count": len(activities),
        "activities": activities
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


def ensure_embedding(activity_id: int) -> bool:
    """
    Genera y guarda el embedding de la actividad si no lo tiene. Se llama
    DESPUÉS del commit de la escritura: la llamada a OpenAI nunca va dentro
    de una transacción y un fallo nunca deshace la actividad (best-effort).
    Devuelve True si la actividad queda con embedding.
    """
    try:
        with connection() as conn:
            row = conn.execute("""
                SELECT a.comentario, c.razon_social AS cliente, t.accion,
                       EXISTS (SELECT 1 FROM activity_embeddings e WHERE e.activity_id = a.id) AS has_embedding
                FROM activities a
                LEFT JOIN clients c ON c.id = a.client_id
                LEFT JOIN activity_types t ON t.id = a.activity_type_id
                WHERE a.id = ?
            """, (activity_id,)).fetchone()
        if row is None:
            return False
        if row["has_embedding"]:
            return True

        text = f"""
    Cliente: {row["cliente"]}
    Acción: {row["accion"]}
    Comentario: {row["comentario"]}
    """
        vector = generate_embedding(text)

        with connection() as conn:
            # Puede haberse borrado o haber recibido ya su embedding mientras tanto
            if conn.execute("SELECT 1 FROM activities WHERE id = ?", (activity_id,)).fetchone() is None:
                return False
            if conn.execute("SELECT 1 FROM activity_embeddings WHERE activity_id = ?", (activity_id,)).fetchone():
                return True
            conn.execute("""
                INSERT INTO activity_embeddings (activity_id, embedding_vector, embedding_model, content_type)
                VALUES (?, ?, ?, ?)
            """, (activity_id, json.dumps(vector), EMBEDDING_MODEL, "activity_full"))
        return True
    except Exception:
        logger.exception("No se pudo generar el embedding de la actividad %s", activity_id)
        return False
