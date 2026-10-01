import json
import math
from db import get_connection
from services.openai_client import create_embedding, get_openai_client

# generate_embedding lanza AIServiceError si OpenAI falla.
client = get_openai_client()


def generate_embedding(text: str):
    return create_embedding(
        client,
        "generate_embedding",
        model="text-embedding-3-small",
        input=text
    )

def cosine_similarity(vec1, vec2):
    dot = sum(a * b for a, b in zip(vec1, vec2))
    norm1 = math.sqrt(sum(a * a for a in vec1))
    norm2 = math.sqrt(sum(b * b for b in vec2))

    if norm1 == 0 or norm2 == 0:
        return 0

    return dot / (norm1 * norm2)



SIMILARITY_THRESHOLD = 0.995

def is_duplicate_activity(new_vector, client_id, activity_type_id, datetime_iso):
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT ae.embedding_vector
        FROM activity_embeddings ae
        JOIN activities a ON a.id = ae.activity_id
        WHERE a.client_id = ?
        AND a.activity_type_id = ?
        AND substr(a.datetime_iso, 1, 10) = ?
        ORDER BY a.created_at DESC
        LIMIT 10
    """, (client_id, activity_type_id, datetime_iso))

    rows = cursor.fetchall()
    conn.close()

    for row in rows:
        stored_vector = json.loads(row["embedding_vector"])
        similarity = cosine_similarity(new_vector, stored_vector)

        if similarity >= SIMILARITY_THRESHOLD:
            return True, similarity

    return False, 0
