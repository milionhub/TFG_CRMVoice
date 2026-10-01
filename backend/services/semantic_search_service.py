import json
import numpy as np
from db import get_connection
from services.openai_client import create_embedding, get_openai_client

client = get_openai_client()

def cosine_similarity(a, b):
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))


def semantic_search_activities(query: str, salesperson_id: int, client_id: int = None, top_k: int = 5):

    # Lanza AIServiceError si OpenAI falla
    query_embedding = np.array(create_embedding(
        client,
        "semantic_search_activities",
        model="text-embedding-3-small",
        input=query
    ))

    conn = get_connection()
    cursor = conn.cursor()

    if client_id:
        cursor.execute("""
            SELECT 
                a.id,
                a.comentario,
                ae.embedding_vector as embedding
            FROM activities a
            JOIN activity_embeddings ae ON a.id = ae.activity_id
            WHERE a.client_id = ? AND a.salesperson_id = ?
            ORDER BY a.id
        """, (client_id, salesperson_id))
    else:
        cursor.execute("""
            SELECT 
                a.id,
                a.comentario,
                ae.embedding_vector as embedding
            FROM activities a
            JOIN activity_embeddings ae ON a.id = ae.activity_id
            WHERE a.salesperson_id = ?
            ORDER BY a.id
        """, (salesperson_id,))

    # 👇 ESTO FALTABA
    rows = cursor.fetchall()

    conn.close()

    results = []

    for row in rows:
        activity_embedding = np.array(json.loads(row["embedding"]))
        similarity = cosine_similarity(query_embedding, activity_embedding)

        results.append({
            "activity_id": row["id"],
            "comentario": row["comentario"],
            "score": similarity
        })

    results = sorted(results, key=lambda x: x["score"], reverse=True)

    return results[:top_k]