"""
Formatos de entrada compartidos por los esquemas y los servicios de escritura (H.2).

- Importes: texto (o entero) en euros -> céntimos (int). Nunca float: se
  interpreta con Decimal y se rechaza lo ambiguo en vez de adivinar.
- Fechas y horas: hora LOCAL del servidor, sin zona horaria (la base guarda
  "YYYY-MM-DDTHH:MM:SS" y "YYYY-MM-DD"). Es la misma suposición que el chat:
  el servidor corre en la zona del usuario (Europe/Madrid).
"""
import re
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

MAX_AMOUNT_CENTS = 1_000_000_000  # 10 millones de euros: tope de cordura, no de negocio

_CURRENCY = re.compile(r"\s*(€|eur|euros?)\s*$", re.IGNORECASE)
# Formas aceptadas (sin espacios ni símbolo):
_PLAIN = re.compile(r"\d+")                                   # 4500
_DECIMAL = re.compile(r"\d+[.,]\d{1,2}")                      # 4500.00 · 4500,00 · 4500,5
_ES_THOUSANDS = re.compile(r"\d{1,3}(\.\d{3})+(,\d{1,2})?")   # 4.500 · 4.500,00 · 1.234.567,89


class FormatError(ValueError):
    """Valor con un formato no válido; el mensaje es apto para el usuario."""


def parse_money_cents(value) -> int:
    """
    Importe en euros -> céntimos. Acepta enteros (euros) y texto en las formas
    habituales en España: "4500", "4500.00", "4500,00", "4.500", "4.500,00".
    Rechaza lo ambiguo ("4,500": ¿cuatro mil quinientos o cuatro con cinco?),
    más de dos decimales, floats, cero y negativos.
    """
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise FormatError("El importe debe ser un número entero de euros o un texto como «4.500,00».")
    if isinstance(value, int):
        euros = Decimal(value)
    else:
        text = _CURRENCY.sub("", value.strip()).replace(" ", "")
        if _PLAIN.fullmatch(text):
            normalized = text
        elif _DECIMAL.fullmatch(text):
            normalized = text.replace(",", ".")
        elif _ES_THOUSANDS.fullmatch(text):
            normalized = text.replace(".", "").replace(",", ".")
        else:
            raise FormatError(f"Importe no válido: «{value.strip()[:30]}». Usa por ejemplo 4500, 4.500 o 4.500,00.")
        try:
            euros = Decimal(normalized)
        except InvalidOperation:
            raise FormatError("Importe no válido.") from None
    cents = euros * 100
    if cents != cents.to_integral_value():
        raise FormatError("El importe no puede tener más de dos decimales.")
    cents = int(cents)
    if cents <= 0:
        raise FormatError("El importe debe ser mayor que cero.")
    if cents > MAX_AMOUNT_CENTS:
        raise FormatError("El importe es demasiado alto.")
    return cents


_DATETIME = re.compile(r"(\d{4}-\d{2}-\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?")


def normalize_datetime(value: str) -> str:
    """"2026-10-02T10:00" / "2026-10-02 10:00:30.000" -> "2026-10-02T10:00:30" (sin milisegundos)."""
    if not isinstance(value, str):
        raise FormatError("La fecha y hora debe tener el formato AAAA-MM-DDTHH:MM.")
    match = _DATETIME.fullmatch(value.strip())
    if not match:
        raise FormatError("La fecha y hora debe tener el formato AAAA-MM-DDTHH:MM.")
    day, hour, minute, second = match.group(1), match.group(2), match.group(3), match.group(4) or "00"
    text = f"{day}T{hour}:{minute}:{second}"
    try:
        datetime.strptime(text, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        raise FormatError("La fecha u hora no existe.") from None
    return text


def parse_date(value: str) -> date:
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value.strip()):
        raise FormatError("La fecha debe tener el formato AAAA-MM-DD.")
    try:
        return date.fromisoformat(value.strip())
    except ValueError:
        raise FormatError("La fecha no existe.") from None


def parse_time(value: str) -> str:
    """"9:30" / "09:30" / "09:30:00" -> "09:30"."""
    match = re.fullmatch(r"(\d{1,2}):(\d{2})(?::\d{2})?", value.strip()) if isinstance(value, str) else None
    if not match or int(match.group(1)) > 23 or int(match.group(2)) > 59:
        raise FormatError("La hora debe tener el formato HH:MM.")
    return f"{int(match.group(1)):02d}:{match.group(2)}"


def capitalize_first(value: str | None) -> str | None:
    """
    Mayúscula inicial PRUDENTE para textos tipo frase (cargo de un contacto,
    concepto de una venta). Política (H4-03):

    - solo se toca la PRIMERA letra y solo si la primera palabra está entera
      en minúsculas: "encargada de proyectos" -> "Encargada de proyectos";
    - el resto del texto no cambia (nada de .title()): "jefe de obra en BBVA"
      -> "Jefe de obra en BBVA";
    - si la primera palabra ya tiene alguna mayúscula se respeta tal cual
      (siglas, marcas, mayúsculas deliberadas): "CEO", "iPhone", "eBay";
    - si no empieza por una letra (cifras, símbolos) no se toca.

    Se aplica a datos de formulario y de IA por igual (esquemas de escritura
    y borradores). No se usa en nombres propios ni en identificadores, ni
    interviene en la detección de duplicados.
    """
    if not value:
        return value
    first_word = value.split(maxsplit=1)[0]
    if not value[0].isalpha() or first_word != first_word.lower():
        return value
    return value[0].upper() + value[1:]


# Palabras de enlace que van en minúscula dentro de un nombre propio ("Ayuntamiento de Valle Alto")
_NAME_CONNECTORS = frozenset({"de", "del", "la", "las", "el", "los", "y", "e", "o", "u", "en", "a", "al",
                              "para", "por", "con", "da", "do", "dos", "das", "i"})
# Formas jurídicas: van en mayúsculas, con o sin puntos ("sl" -> "SL", "s.l." -> "S.L.")
_LEGAL_FORMS = frozenset({"sl", "sa", "slu", "sll", "sc", "scp", "cb", "sau", "slp"})


def _name_word(word: str, first: bool) -> str:
    if word != word.lower() or not word[:1].isalpha():
        return word                      # ya tiene mayúsculas (NASA, CRMVoice, IT, iPhone) o empieza por cifra
    if word.replace(".", "") in _LEGAL_FORMS:
        return word.upper()
    if word in _NAME_CONNECTORS and not first:
        return word
    # "castilla-la" -> "Castilla-La"; "l'hospitalet" -> "L'Hospitalet"
    return re.sub(r"(^|[-'’])(\w)", lambda m: m.group(1) + m.group(2).upper(), word)


def name_case(value: str | None) -> str | None:
    """
    Mayúsculas profesionales para NOMBRES PROPIOS dictados (razón social,
    alias, población, provincia, nombre de una persona o de un producto),
    centralizado aquí junto a capitalize_first (I.8). Política conservadora:

    - SOLO si el valor llega ENTERO en minúsculas (casing pobre del ASR):
      "academia oasis" -> "Academia Oasis", "santa pola" -> "Santa Pola";
    - si ya trae alguna mayúscula, se respeta TAL CUAL (casing significativo:
      "NASA Academia", "NOVA digital", "CRMVoice", "IT soluciones", "S.L."),
      aunque alguna palabra vaya en minúscula; el usuario puede editarlo;
    - palabras de enlace en minúscula salvo al principio:
      "ayuntamiento de valle alto" -> "Ayuntamiento de Valle Alto";
    - formas jurídicas en mayúsculas: "rivera sl" -> "Rivera SL", "s.l." -> "S.L.";
    - lo que empieza por cifra o símbolo no se toca. Nada de .title().

    NO es para cargos ni frases (eso es capitalize_first), ni para emails,
    CIF, teléfonos o texto libre. Solo cambia mayúsculas: el contenido dicho
    se conserva (nunca se sustituye un nombre nuevo por uno parecido).
    """
    if not value or value != value.lower():
        return value
    words = value.split(" ")
    return " ".join(_name_word(w, i == 0) if w else w for i, w in enumerate(words))


def iso_now(now: datetime) -> str:
    return now.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%S")
