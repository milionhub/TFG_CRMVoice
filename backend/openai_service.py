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
    Eres un consultor CRM experto en preparación de reuniones comerciales estratégicas.

    Tu tarea es generar un briefing ejecutivo que ayude a un comercial a prepararse para una reunión con el cliente.

    DATOS DEL CLIENTE
    -----------------
    Nombre: {context_data["client_name"]}
    Total actividades: {context_data["total_activities"]}
    Último contacto: {context_data["last_contact_date"]}
    Tipo de interacción más frecuente: {context_data["frequent_activity_type"]}

    FACTURACIÓN
    -----------
    Facturación total: {billing.get("total_facturado", 0)} €
    Número de facturas: {billing.get("total_facturas", 0)}
    Ticket medio: {billing.get("ticket_medio", 0)} €
    Última factura: {billing.get("ultima_factura", "N/A")}
    Producto con mayor facturación: {billing.get("producto_top", "N/A")}

    ÚLTIMAS INTERACCIONES
    ---------------------
    {recent_activities_formatted}

    INSTRUCCIONES:

    Genera un briefing estructurado con:

    ### 1️⃣ Resumen Ejecutivo
    Resumen breve del estado de la cuenta.

    ### 2️⃣ Contexto Comercial
    Qué está pasando actualmente con este cliente.

    ### 3️⃣ Temas Clave para la Reunión
    3-4 puntos que el comercial debería tratar.

    ### 4️⃣ Oportunidades
    Posibles oportunidades de negocio detectadas.

    ### 5️⃣ Riesgos
    Posibles señales de alerta.

    ### 6️⃣ Próximos Pasos
    Acciones concretas que el comercial debería proponer.

    El briefing debe ser claro, accionable y orientado a negocio.
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
    Eres un consultor senior especializado en análisis de clientes B2B para equipos comerciales.

    Tu objetivo es generar un análisis estratégico del cliente basado en actividad comercial y facturación.

    DATOS DEL CLIENTE
    -----------------
    Nombre: {context_data["client_name"]}
    Total actividades registradas: {context_data["total_activities"]}
    Último contacto: {context_data["last_contact_date"]}
    Tipo de interacción más frecuente: {context_data["frequent_activity_type"]}

    FACTURACIÓN
    -----------
    Facturación histórica: {billing["total_facturado"]} €
    Número de facturas: {billing["total_facturas"]}
    Ticket medio: {billing["ticket_medio"]} €
    Última factura: {billing["ultima_factura"]}
    Producto más facturado: {billing["producto_top"]}

    INTERACCIONES RECIENTES
    -----------------------
    {recent_activities_formatted}

    INSTRUCCIONES:

    Analiza la información y genera un informe estructurado con estas secciones:

    ### 1️⃣ Estado del Cliente
    Clasifica al cliente en uno de estos niveles:
    - Estratégico
    - Recurrente
    - En crecimiento
    - Bajo potencial
    - Riesgo de abandono

    Explica brevemente por qué.

    ### 2️⃣ Actividad Comercial
    Evalúa si la actividad comercial es:
    - Alta
    - Media
    - Baja

    y si está alineada con la facturación.

    ### 3️⃣ Oportunidades Comerciales
    Detecta posibles oportunidades de negocio.

    Ejemplos:
    - upsell
    - cross sell
    - expansión de cuenta
    - mayor frecuencia de contacto

    ### 4️⃣ Riesgos Potenciales
    Indica riesgos como:
    - baja actividad reciente
    - caída en facturación
    - falta de seguimiento

    ### 5️⃣ Recomendaciones
    Propón 2-3 acciones concretas para el equipo comercial.

    Usa lenguaje claro, profesional y orientado a negocio.
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

def generate_account_analysis(context_data):

    billing = context_data["billing"]

    recent_activities_formatted = "\n".join(
        f"- {a}" for a in context_data["recent_activities"]
    )

    prompt = f"""
    Eres un analista CRM experto en gestión de cuentas B2B.

    Tu tarea es analizar una cuenta de cliente utilizando actividad comercial y facturación.

    CLIENTE
    -------
    Nombre: {context_data["client_name"]}
    Total actividades: {context_data["total_activities"]}
    Último contacto: {context_data["last_contact_date"]}
    Actividad más frecuente: {context_data["frequent_activity_type"]}

    FACTURACIÓN
    -----------
    Facturación total: {billing["total_facturado"]} €
    Número de facturas: {billing["total_facturas"]}
    Ticket medio: {billing["ticket_medio"]} €

    ACTIVIDAD RECIENTE
    ------------------
    {recent_activities_formatted}

    Genera un análisis ejecutivo con:

    ### Estado de la cuenta
    ### Nivel de actividad comercial
    ### Potencial de negocio
    ### Riesgos
    ### Recomendaciones estratégicas

    Usa lenguaje profesional y orientado a negocio.
    Evita párrafos largos.
    """

    response = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": "Eres un analista CRM experto en cuentas B2B."},
            {"role": "user", "content": prompt}
        ],
        temperature=0.3
    )

    return response.choices[0].message.content
