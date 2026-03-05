import os
from openai import OpenAI
import math
from db import get_connection

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

    billing = context_data.get("billing", {})

    prompt = f"""
Eres un consultor CRM senior especializado en preparación de reuniones ejecutivas.

Tu objetivo es generar un briefing claro, estructurado y fácil de leer.

DATOS DEL CLIENTE
-----------------
Nombre: {context_data["client_name"]}
Total actividades registradas: {context_data["total_activities"]}
Último contacto: {context_data["last_contact_date"]}
Actividad más frecuente: {context_data["frequent_activity_type"]}

INFORMACIÓN FINANCIERA
----------------------
Facturación total histórica: {billing.get("total_facturado", 0)} €
Número de facturas: {billing.get("total_facturas", 0)}
Ticket medio: {billing.get("ticket_medio", 0)} €
Última factura registrada: {billing.get("ultima_factura", "N/A")}
Producto con mayor facturación: {billing.get("producto_top", "N/A")}

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

Analiza también la relación entre actividad comercial y facturación.
Si hay alta actividad pero baja facturación, indícalo.
Si es una cuenta estratégica por volumen, indícalo.
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


def cosine_similarity(vec1, vec2):
    dot = sum(a * b for a, b in zip(vec1, vec2))
    norm1 = math.sqrt(sum(a * a for a in vec1))
    norm2 = math.sqrt(sum(b * b for b in vec2))

    if norm1 == 0 or norm2 == 0:
        return 0

    return dot / (norm1 * norm2)



SIMILARITY_THRESHOLD = 0.995

def is_duplicate_activity(new_vector, client_id, activity_type_id, fecha_iso):
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
    """, (client_id, activity_type_id, fecha_iso))

    rows = cursor.fetchall()
    conn.close()

    for row in rows:
        stored_vector = eval(row["embedding_vector"])
        similarity = cosine_similarity(new_vector, stored_vector)

        if similarity >= SIMILARITY_THRESHOLD:
            return True, similarity

    return False, 0


def format_billing_response(billing_data):

    return f"""
Resumen de Facturación

Facturación total histórica: {billing_data["total_facturado"]} €
Número de facturas: {billing_data["total_facturas"]}
Ticket medio: {billing_data["ticket_medio"]} €
Última factura registrada: {billing_data["ultima_factura"]}
Producto más facturado: {billing_data["producto_top"]}
"""


def generate_client_summary(context_data: dict):

    recent_activities_formatted = "\n".join(
        f"- {activity}" for activity in context_data["recent_activities"]
    )

    billing = context_data["billing"]

    prompt = f"""
Eres un consultor estratégico CRM senior.

Genera un análisis ejecutivo del cliente con enfoque comercial.

DATOS
-----
Nombre: {context_data["client_name"]}
Total actividades: {context_data["total_activities"]}
Último contacto: {context_data["last_contact_date"]}
Actividad más frecuente: {context_data["frequent_activity_type"]}

Facturación histórica: {billing["total_facturado"]} €
Número de facturas: {billing["total_facturas"]}
Ticket medio: {billing["ticket_medio"]} €
Última factura: {billing["ultima_factura"]}
Producto más facturado: {billing["producto_top"]}

Últimas interacciones:
{recent_activities_formatted}

INSTRUCCIONES:

- Redacta un resumen ejecutivo claro (máx 8 líneas).
- Evalúa nivel de cliente (estratégico, recurrente, bajo potencial, nuevo, etc).
- Indica estado comercial actual.
- Señala oportunidades claras.
- Señala riesgos si existen.
- Usa tono profesional.
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