"""
Fechas relativas en lenguaje natural (I.7), deterministas y sin reloj propio:
toda resolución recibe la fecha base (`today`) de quien llama, que en el
Action Engine es el `now` de la petición (inyectable en los tests). Nada de
aquí lee datetime.now() ni la zona horaria del proceso.

El intérprete (LLM) solo COPIA la expresión tal como se dijo (date_said:
"pasado mañana", "el próximo lunes"); el día lo calcula resolve_day(). Si la
expresión no se reconoce (una fecha absoluta, "el día 15", algo compuesto),
devuelve None y se usa la fecha que propuso el intérprete con el calendario
del contexto (también generado aquí: calendar_context()).

Convenciones (documentadas y probadas):
- hoy / esta mañana / esta tarde / esta noche = hoy; mañana = +1;
  pasado mañana = +2; ayer = -1; anteayer / antes de ayer = -2.
- "el sábado", "sábado", "el próximo sábado", "el sábado que viene", "el
  siguiente sábado": el PRÓXIMO sábado estrictamente posterior a hoy (de +1 a
  +7). "Próximo" es el que sigue inmediatamente (criterio de la RAE/Fundéu),
  no el de la semana siguiente.
- "este sábado": el sábado más cercano contando hoy (de 0 a +6).
- "el sábado de la semana que viene" / "de la próxima semana" / "la semana
  que viene, el sábado": el sábado de la semana siguiente (semanas de lunes
  a domingo, como el calendario del chat).
- "el sábado pasado" / "el pasado sábado": el anterior estrictamente a hoy.
- Una acción YA HECHA (status completed: "el lunes llamé a Marta") con un
  día de la semana sin más ("el lunes") es el anterior (de -1 a -7), y "este
  lunes" el más cercano hacia atrás contando hoy (de 0 a -6).
- Varias expresiones distintas en el mismo texto ("mañana o el lunes"): no se
  elige ninguna (None).
"""
import re
import unicodedata
from datetime import date, timedelta

WEEKDAYS = ("lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo")
WEEKDAY_LABELS = ("lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo")

_DAY = "|".join(WEEKDAYS)
_NEXT_WEEK = r"(?:de |para )?la (?:semana que viene|proxima semana|semana siguiente)"

# (patrón, tipo) en orden: lo más específico primero
_WEEKDAY_RULES = (
    (re.compile(rf"\b({_DAY})\s+{_NEXT_WEEK}"), "next_week"),
    (re.compile(rf"{_NEXT_WEEK}\s*,?\s*(?:el\s+)?({_DAY})\b"), "next_week"),
    (re.compile(rf"\b(?:el\s+)?({_DAY})\s+pasado\b"), "past"),
    (re.compile(rf"\b(?:el\s+)?pasado\s+({_DAY})\b"), "past"),
    (re.compile(rf"\b(?:el\s+)?(?:proximo|siguiente)\s+({_DAY})\b"), "next"),
    (re.compile(rf"\b({_DAY})\s+(?:que viene|proximo|siguiente)\b"), "next"),
    (re.compile(rf"\best[ea]\s+({_DAY})\b"), "this"),
    (re.compile(rf"\b({_DAY})\b"), "bare"),
)
_RELATIVE_RULES = (
    (re.compile(r"\bpasad[oa]\s+manana\b"), 2),          # "pasada mañana": error habitual del ASR
    (re.compile(r"\b(?:anteayer|antes\s+de\s+ayer)\b"), -2),
    (re.compile(r"\bayer\b"), -1),
    (re.compile(r"\b(?:hoy|esta\s+(?:manana|tarde|noche))\b"), 0),
    (re.compile(r"\bmanana\b"), 1),
)
# "por la mañana" / "de la mañana" son una franja horaria, no un día
_TIME_OF_DAY = re.compile(r"\b(?:por|de|a)\s+la\s+(?:manana|tarde|noche)\b")


def _normalize(text: str) -> str:
    text = "".join(c for c in unicodedata.normalize("NFD", text.casefold()) if unicodedata.category(c) != "Mn")
    return " ".join(re.sub(r"[^\w\s]", " ", text).split())


def _weekday_date(kind: str, weekday: int, today: date, completed: bool) -> date:
    delta = (weekday - today.weekday()) % 7          # 0..6 hacia delante
    if kind == "next_week":
        monday = today - timedelta(days=today.weekday()) + timedelta(days=7)
        return monday + timedelta(days=weekday)
    if kind == "past" or (kind == "bare" and completed):
        return today - timedelta(days=(today.weekday() - weekday) % 7 or 7)
    if kind == "this":
        if completed:
            return today - timedelta(days=(today.weekday() - weekday) % 7)
        return today + timedelta(days=delta)
    return today + timedelta(days=delta or 7)        # next / bare: estrictamente posterior


def resolve_day(said: str | None, today: date, *, completed: bool = False) -> date | None:
    """Día que significa `said` respecto a `today`, o None si no es una expresión relativa reconocida."""
    if not said or not isinstance(said, str):
        return None
    text = _TIME_OF_DAY.sub(" ", _normalize(said))
    found: set[date] = set()

    rest = text
    for pattern, kind in _WEEKDAY_RULES:
        for match in pattern.finditer(rest):
            found.add(_weekday_date(kind, WEEKDAYS.index(match.group(1)), today, completed))
        rest = pattern.sub(" ", rest)
    for pattern, offset in _RELATIVE_RULES:
        if pattern.search(rest):
            found.add(today + timedelta(days=offset))
        rest = pattern.sub(" ", rest)

    return found.pop() if len(found) == 1 else None


# --- Horas ------------------------------------------------------------------

_HOUR_WORDS = {"una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7,
               "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12}
_HOUR = r"(\d{1,2}|" + "|".join(_HOUR_WORDS) + r")"
# "a las 5", "a la una", "a las 10 30" (10:30 tras normalizar), "a las 9 y media", "a las 6 menos cuarto",
# con o sin "de/por la mañana|tarde|noche", "del mediodía" o "en punto"
_TIME = re.compile(
    rf"\ba\s+las?\s+{_HOUR}"
    r"(?:\s+y\s+(media|cuarto)|\s+menos\s+(cuarto)|\s+(\d{2})(?!\d))?"
    r"(?:\s+en\s+punto)?"
    r"(?:\s+(?:de|por)\s+la\s+(manana|tarde|noche)|\s+del?\s+mediodia)?"
    r"(?:\s+en\s+punto)?\b"
)


def _clock(hour: int, period: str | None, midday: bool) -> int | None:
    """Hora en 24 h, o None si es ambigua ("a las 5" sin más: ¿05:00 o 17:00?)."""
    if hour > 23:
        return None
    if hour > 12 or hour == 0:
        return hour                                 # ya es 24 h ("a las 17")
    if midday:
        return 12 if hour == 12 else (hour + 12 if hour <= 3 else None)
    if period == "tarde":
        return 12 if hour == 12 else hour + 12
    if period == "noche":
        return None if hour == 12 else (hour if hour <= 5 else hour + 12)
    if period == "manana":
        return None if hour == 12 else hour
    return 12 if hour == 12 else None               # "a las doce" = 12:00; "a las 5" es ambigua


def resolve_time(text: str | None) -> str | None:
    """
    Hora "HH:MM" de una expresión INEQUÍVOCA del texto ("a las 5 de la tarde"
    -> 17:00, "a las seis de la tarde" -> 18:00, "a las doce" -> 12:00,
    "a las 17" -> 17:00, "a las 9 y media de la mañana" -> 09:30). Sin
    franja ("a las 5"), o con varias horas en el texto, devuelve None y
    manda la hora del intérprete. Determinista y sin reloj.
    """
    if not text or not isinstance(text, str):
        return None
    matches = list(_TIME.finditer(_normalize(text)))
    if len(matches) != 1:
        return None
    m = matches[0]
    raw, half_quarter, minus_quarter, minutes, period = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
    midday = "mediodia" in m.group(0)
    hour = _HOUR_WORDS.get(raw) or int(raw)
    minute = 0
    if half_quarter:
        minute = 30 if half_quarter == "media" else 15
    elif minutes is not None:
        minute = int(minutes)
        if minute > 59 or not raw.isdigit():
            return None
    clock = _clock(hour, period, midday)
    if clock is None:
        return None
    if minus_quarter:
        clock, minute = (clock - 1) % 24, 45
    return f"{clock:02d}:{minute:02d}"


def calendar_context(today: date) -> dict:
    """Tabla de días para el contexto del intérprete, calculada con las MISMAS reglas que resolve_day."""
    upcoming = {WEEKDAY_LABELS[d]: _weekday_date("next", d, today, False).isoformat() for d in range(7)}
    previous = {WEEKDAY_LABELS[d]: _weekday_date("past", d, today, False).isoformat() for d in range(7)}
    return {
        "pasado_mañana": (today + timedelta(days=2)).isoformat(),
        "anteayer": (today - timedelta(days=2)).isoformat(),
        "proximo_dia_de_la_semana": upcoming,
        "ultimo_dia_de_la_semana": previous,
    }


__all__ = ["resolve_day", "resolve_time", "calendar_context", "WEEKDAYS", "WEEKDAY_LABELS"]
