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

def generate_meeting_summary(context_data: dict):

    recent_activities_formatted = "\n".join(
        f"- {activity}" for activity in context_data["recent_activities"]
    )

    prompt = f"""
Eres un consultor CRM senior especializado en preparación de reuniones ejecutivas.

Tu objetivo es generar un briefing claro, estructurado y fácil de leer.

DATOS DEL CLIENTE
-----------------
Nombre: {context_data["client_name"]}
Total actividades registradas: {context_data["total_activities"]}
Último contacto: {context_data["last_contact_date"]}
Actividad más frecuente: {context_data["frequent_activity_type"]}
Facturación acumulada: {context_data["billing_total"]}

ÚLTIMAS INTERACCIONES
---------------------
{recent_activities_formatted}

INSTRUCCIONES:

Devuelve la información con el siguiente formato exacto:

### 1️⃣ Resumen Ejecutivo
(Párrafo corto de máximo 6 líneas)

### 2️⃣ Puntos Clave a Tratar
- Punto 1
- Punto 2
- Punto 3

### 3️⃣ Oportunidades Detectadas
- Oportunidad 1
- Oportunidad 2

### 4️⃣ Riesgos Potenciales
- Riesgo 1
- Riesgo 2

### 5️⃣ Próximos Pasos Recomendados
- Acción 1
- Acción 2

Usa tono profesional, claro y estratégico.
Evita párrafos largos.
    """

    response = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": "Eres un consultor CRM experto en estrategia comercial B2B."},
            {"role": "user", "content": prompt}
        ],
        temperature=0.3
    )

    return response.choices[0].message.content
