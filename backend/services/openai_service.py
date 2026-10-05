from services.openai_client import create_embedding, get_openai_client

# generate_embedding lanza AIServiceError si OpenAI falla. (La detección de duplicados por
# embeddings, B2, se eliminó en H.2: ahora es determinista en services/writes/activities.py.)
client = get_openai_client()


def generate_embedding(text: str):
    return create_embedding(
        client,
        "generate_embedding",
        model="text-embedding-3-small",
        input=text
    )
