import json
import re
from openai import OpenAI
import os

client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

def extract_json(text: str):
    """
    Extrae el primer bloque JSON válido de un texto
    """
    try:
        return json.loads(text)
    except:
        pass

    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group())
        except:
            pass

    return None


def analyze_user_message(message: str):

    prompt = f"""
    Analiza el mensaje del usuario en un CRM.

    Devuelve SOLO JSON válido, sin explicaciones.

    {{
      "intent": "prepare_meeting | client_summary | billing_query | semantic_search | crm_insights | client_analysis | client_opportunities | general",
      "client_name": string o null,
      "confidence": número de 0 a 100
    }}

    Mensaje:
    "{message}"
    """

    try:
        response = client.chat.completions.create(
            model="gpt-4o-mini",
            temperature=0,
            messages=[
                {"role": "system", "content": "Responde SOLO con JSON válido."},
                {"role": "user", "content": prompt}
            ]
        )

        content = response.choices[0].message.content.strip()

        print("RAW AI RESPONSE:", content)

        parsed = extract_json(content)

        if parsed:
            return parsed

        return {
            "intent": None,
            "client_name": None,
            "confidence": 0
        }

    except Exception as e:
        print("AI Router error:", e)
        return {
            "intent": None,
            "client_name": None,
            "confidence": 0
        }