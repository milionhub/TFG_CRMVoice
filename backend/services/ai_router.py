import json
import logging
import math
import re

from services.openai_client import AIServiceError, chat_completion_text, get_openai_client

logger = logging.getLogger("crmvoice")

client = get_openai_client()

# Respuesta cuando el router no es fiable: el chat usa el detector por palabras
UNRELIABLE_ANALYSIS = {"intent": None, "client_name": None, "confidence": 0}


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


def _validate_analysis(parsed) -> dict | None:
    """
    Contrato mínimo de la salida del router: {intent: str|None,
    client_name: str|None, confidence: número en [0, 100]}. Devuelve None si
    no lo cumple (confidence ausente cuenta como 0).
    """
    if not isinstance(parsed, dict):
        return None

    intent = parsed.get("intent")
    client_name = parsed.get("client_name")
    confidence = parsed.get("confidence", 0)

    if intent is not None and not isinstance(intent, str):
        return None
    if client_name is not None and not isinstance(client_name, str):
        return None
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        return None
    if not math.isfinite(confidence) or not 0 <= confidence <= 100:
        return None

    return {"intent": intent, "client_name": client_name, "confidence": confidence}


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
        content = chat_completion_text(
            client,
            "analyze_user_message",
            model="gpt-4o-mini",
            temperature=0,
            messages=[
                {"role": "system", "content": "Responde SOLO con JSON válido."},
                {"role": "user", "content": prompt}
            ]
        )
    except AIServiceError:
        return dict(UNRELIABLE_ANALYSIS)

    analysis = _validate_analysis(extract_json(content.strip()))

    if analysis is None:
        logger.warning("Salida del router IA fuera de contrato: se usa el detector por palabras")
        return dict(UNRELIABLE_ANALYSIS)

    return analysis
