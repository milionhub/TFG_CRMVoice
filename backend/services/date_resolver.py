from datetime import datetime, timedelta
import re

def resolve_relative_date(text: str, today: datetime | None = None) -> str | None:
    """
    Detecta fechas relativas y las convierte a formato ISO YYYY-MM-DD.
    `today` es la fecha base (por defecto, la actual); los tests la fijan.
    """
    if not text:
        return None

    if today is None:
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


# Horas dichas con palabras ("a las cuatro y media"); "una" por "a la una"
HOUR_WORDS = {
    "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6,
    "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12,
}

# "a las 6", "a la una", "a las 4 y media", "a las cinco menos cuarto"
_SPOKEN_TIME = re.compile(
    r"a la?s? (\d{1,2}|" + "|".join(HOUR_WORDS) + r")\b"
    r"(?:\s+(y media|y cuarto|menos cuarto)\b)?"
)


def _format_time(hour: int, minute: int) -> str | None:
    """HH:MM:SS, o None si la hora no existe (p. ej. "a las 25")."""
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    return f"{hour:02d}:{minute:02d}:00"


def resolve_time(text: str) -> str | None:
    """
    Detecta hora en texto tipo:
    - a la 6 / a la una
    - a las 6 / a las seis
    - a las 6 de la tarde
    - a las 4 y media / y cuarto / a las 5 menos cuarto
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
        return _format_time(int(hour), int(minute))

    # 2️⃣ Formato "a la 6", "a las 6", con o sin fracción y mañana/tarde/noche
    match = _SPOKEN_TIME.search(lower)
    if match:
        raw_hour, fraction = match.groups()
        hour = int(raw_hour) if raw_hour.isdigit() else HOUR_WORDS[raw_hour]

        if hour > 23:
            return None

        # La fracción se aplica a la hora nombrada, antes de mañana/tarde/noche:
        # "las cinco menos cuarto de la tarde" = 16:45
        minute = 0
        if fraction == "y media":
            minute = 30
        elif fraction == "y cuarto":
            minute = 15
        elif fraction == "menos cuarto":
            hour, minute = (hour - 1) % 24, 45

        if re.search(r"\b(tarde|noche)\b", lower):
            if hour < 12:
                hour += 12

        # Solo la franja horaria ("de/por la mañana"), no el día "mañana"
        if re.search(r"\b(de|por) la mañana\b", lower) and hour == 12:
            hour = 0  # 12 de la mañana = 00

        return _format_time(hour, minute)

    return None