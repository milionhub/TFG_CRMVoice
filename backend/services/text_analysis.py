"""
Análisis del texto dictado con reglas (regex): cliente, contacto, acción y fecha.

Es lo que devuelve /process-text y el primer paso de /process-audio.
"""
import re

from services.date_resolver import resolve_relative_date


def normalize_name(name: str) -> str:
    return " ".join(word.capitalize() for word in name.split())


def detect_cliente(text: str) -> str | None:
    """
    Detecta empresa tras:
    - de García Sistemas
    - empresa García Sistemas
    """

    patterns = [
        r"(?:empresa|cliente)\s+([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ\s]+)",
        r"de\s+([A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñ\s]+?)(?:\s|$)",
    ]

    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            candidate = match.group(1).strip()

            # Limitar a máximo 3 palabras (evita capturar frases enteras)
            words = candidate.split()
            if len(words) <= 3:
                return normalize_name(candidate)

    return None


def detect_action(text: str) -> str | None:
    rules = [
        (r"enviar.*presupuesto|presupuesto", "Enviar presupuesto"),
        (r"enviar.*oferta|oferta", "Enviar oferta"),
        (r"concertar.*reunión|reunión|reunion", "Concertar reunión"),
        (r"visita", "Registrar visita comercial"),
        (r"llamada|llamar", "Realizar llamada de seguimiento"),
    ]

    lower = text.lower()
    for pattern, action in rules:
        if re.search(pattern, lower):
            return action

    return None


def detect_contact(text: str) -> str | None:
    """
    Detecta:
    - Laura Gómez
    - Laura
    - He hablado con Laura
    - Reunión con Laura Gómez
    """

    patterns = [
        # Laura Gómez
        r"(?:hablado con|reunión con|con)\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñ]+(?:\s+[A-ZÁÉÍÓÚÑ][a-záéíóúñ]+)?)",

        # Nombre completo aislado
        r"\b([A-ZÁÉÍÓÚÑ][a-záéíóúñ]+\s+[A-ZÁÉÍÓÚÑ][a-záéíóúñ]+)\b",

        # Solo primer nombre (pero NO si va seguido de 'de')
        r"\b([A-ZÁÉÍÓÚÑ][a-záéíóúñ]+)\b(?!\s+de)"
    ]

    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return match.group(1)

    return None


def analyze_text(text: str) -> dict:
    contacto = detect_contact(text)
    cliente = detect_cliente(text)

    return {
        "cliente": cliente,
        "contacto": contacto,
        "accion": detect_action(text),
        "fecha": resolve_relative_date(text),
        "comentario": text,
    }
