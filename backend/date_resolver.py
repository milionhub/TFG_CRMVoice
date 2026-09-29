from datetime import datetime, timedelta
import re

def resolve_relative_date(text: str) -> str | None:
    """
    Detecta fechas relativas y las convierte a formato ISO YYYY-MM-DD
    """
    if not text:
        return None

    today = datetime.today()
    lower = text.lower()

    # "de la mañana" / "por la mañana" indican franja horaria, no el día de mañana
    # ("mañana por la mañana" sigue detectándose por el primer "mañana")
    lower = re.sub(r"\b(de|por) la mañana\b", " ", lower)

    # ----------------------
    # CASOS DIRECTOS
    # ----------------------

    if re.search(r"\bhoy\b", lower) or re.search(r"\besta mañana\b", lower):
        return today.strftime("%Y-%m-%d")

    # "pasado mañana" debe comprobarse antes que "mañana"
    if re.search(r"\bpasado mañana\b", lower):
        return (today + timedelta(days=2)).strftime("%Y-%m-%d")

    if re.search(r"\bmañana\b", lower):
        return (today + timedelta(days=1)).strftime("%Y-%m-%d")

    if "la semana que viene" in lower:
        return (today + timedelta(days=7)).strftime("%Y-%m-%d")

    # ----------------------
    # DÍAS DE LA SEMANA
    # ----------------------

    weekdays = {
        "lunes": 0,
        "martes": 1,
        "miércoles": 2,
        "miercoles": 2,
        "jueves": 3,
        "viernes": 4,
        "sábado": 5,
        "sabado": 5,
        "domingo": 6,
    }

    for day, weekday in weekdays.items():
        if re.search(rf"\b{day}\b", lower):
            days_ahead = (weekday - today.weekday() + 7) % 7
            days_ahead = 7 if days_ahead == 0 else days_ahead
            return (today + timedelta(days=days_ahead)).strftime("%Y-%m-%d")

    # ----------------------
    # FECHA EXPLÍCITA
    # ----------------------

    match = re.search(r"\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b", text)
    if match:
        day, month, year = match.groups()
        year = "20" + year if len(year) == 2 else year
        try:
            return datetime(int(year), int(month), int(day)).strftime("%Y-%m-%d")
        except ValueError:
            return None

    return None


def resolve_time(text: str) -> str | None:
    """
    Detecta hora en texto tipo:
    - a la 6
    - a las 6
    - a las 6 de la tarde
    - 18:30
    - 6 de la mañana
    """

    if not text:
        return None

    lower = text.lower()

    # 1️⃣ Formato 18:30
    match = re.search(r"\b(\d{1,2}):(\d{2})\b", lower)
    if match:
        hour, minute = match.groups()
        return f"{int(hour):02d}:{int(minute):02d}:00"

    # 2️⃣ Formato "a la 6", "a las 6", con o sin mañana/tarde/noche
    match = re.search(r"a la?s? (\d{1,2})", lower)
    if match:
        hour = int(match.group(1))

        if re.search(r"\b(tarde|noche)\b", lower):
            if hour < 12:
                hour += 12

        # Solo la franja horaria ("de/por la mañana"), no el día "mañana"
        if re.search(r"\b(de|por) la mañana\b", lower) and hour == 12:
            hour = 0  # 12 de la mañana = 00

        return f"{hour:02d}:00:00"

    return None