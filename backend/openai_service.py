import os
from openai import OpenAI

api_key = os.getenv("OPENAI_API_KEY")

if not api_key:
    raise ValueError("OPENAI_API_KEY no encontrada en entorno")

client = OpenAI(api_key=api_key)


def generate_embedding(text: str):
    response = client.embeddings.create(
        model="text-embedding-3-small",
        input=text
    )
    return response.data[0].embedding

def test_embedding():
    response = client.embeddings.create(
        model="text-embedding-3-small",
        input="Prueba CRM Voice"
    )
    return response.data[0].embedding
