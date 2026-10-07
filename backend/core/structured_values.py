"""
Normalización determinista de valores ESTRUCTURADOS dictados (I.7): teléfono,
email y CIF/NIF/NIE tal como los deja una transcripción (Whisper) o el
intérprete ("6-1-1-2-3-4-5-6-7", "paula arroba empresa punto es", "B 54 321 678").

Política (conservadora):
- solo se transforma cuando el resultado es INEQUÍVOCO y tiene el formato
  canónico del CRM; si no, se devuelve el valor tal cual (solo con los
  espacios recortados) y la validación de siempre decide (ClientIn/ContactIn);
- solo para campos estructurados: nunca se aplica a nombres, razones
  sociales, cargos, comentarios ni texto libre;
- la transcripción original no se toca (source_text del borrador).

Formatos canónicos (los de los datos existentes): teléfono "611234567" (o
"+34611234567" si se dijo el prefijo), email en minúsculas, CIF/NIF/NIE en
mayúsculas sin separadores ("B54321678").
"""
import re
import unicodedata

# --- Teléfono -------------------------------------------------------------

# Separadores que el ASR o el dictado ponen entre cifras
_PHONE_SEPARATORS = re.compile(r"[\s.\-·/()]+")
_SPANISH_NUMBER = re.compile(r"[6789]\d{8}")              # móvil o fijo español: 9 cifras
_DIGIT_WORDS = {"cero": "0", "uno": "1", "un": "1", "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5",
                "seis": "6", "siete": "7", "ocho": "8", "nueve": "9"}
_COUNTRY_PREFIX = re.compile(r"^(?:\+|00|mas\s*)34")


def _strip_accents(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")


def _spoken_digits(text: str) -> str:
    """"seis uno uno ..." -> "611...": SOLO si todas las palabras son cifras sueltas (sin "once", "doscientos"...)."""
    words = text.split()
    if words and all(w in _DIGIT_WORDS or w.isdigit() for w in words) and any(w in _DIGIT_WORDS for w in words):
        return "".join(_DIGIT_WORDS.get(w, w) for w in words)
    return text


def normalize_phone(value: str | None) -> str | None:
    """
    Teléfono español a 9 cifras seguidas, con "+34" delante solo si se dijo.
    "611 234 567", "611-234-567", "6-1-1-2-3-4-5-6-7", "seis uno uno ..." -> "611234567".
    Cualquier otra cosa (otro número de cifras, letras...) se devuelve tal cual.
    """
    if value is None:
        return None
    original = " ".join(str(value).split())
    if not original:
        return None
    text = _spoken_digits(_strip_accents(original.casefold()))
    text = _PHONE_SEPARATORS.sub("", text)
    prefix = ""
    if (match := _COUNTRY_PREFIX.match(text)) and len(text) - match.end() == 9:
        prefix, text = "+34", text[match.end():]
    if _SPANISH_NUMBER.fullmatch(text):
        return prefix + text
    return original


def phone_review_message(phone: str | None) -> str | None:
    """
    Aviso (no bloquea) para un teléfono sin prefijo internacional cuyo número
    de cifras no es el de un teléfono español (9). Nunca se quitan ni se
    añaden cifras: si el dictado trajo una de más ("9654321100"), el usuario
    lo ve en la revisión y lo corrige. Con "+" (internacional) no se avisa.
    """
    if not phone or phone.startswith("+") or not re.fullmatch(r"[0-9 .\-()/]+", phone):
        return None
    digits = len(re.sub(r"\D", "", phone))
    if digits == 9 or digits < 6:          # < 6: ya lo rechaza la validación del teléfono
        return None
    return f"El teléfono tiene {digits} cifras y un teléfono español tiene 9: revísalo antes de guardar."


# --- Email ------------------------------------------------------------------

_EMAIL = re.compile(r"[a-z0-9._%+\-ñ]+@[a-z0-9\-ñ]+(\.[a-z0-9\-ñ]+)*\.[a-z]{2,}")
# Dominios de primer nivel que se aceptan "pegados" ("empresapuntoes" -> "empresa.es")
_GLUED_TLD = re.compile(r"punto(es|com|net|org|eu|cat|info|io)$")
# (el texto ya va sin tildes: "guión" -> "guion")
_SPOKEN = (("guion bajo", "_"), ("barra baja", "_"), ("guion", "-"))


def _without_accents_keep_enye(text: str) -> str:
    return "".join(_strip_accents(c) if c not in "ñÑ" else c for c in text)


def normalize_email(value: str | None) -> str | None:
    """
    Email dictado -> dirección. Reglas, solo si el resultado es un email válido:
    - "arroba" (una sola vez, separada o pegada; también las variantes del
      ASR "a roba", "aroba") -> "@"; "punto"/"dot" entre palabras -> ".";
      "guion" -> "-"; "guion bajo" -> "_"; sin la puntuación accidental de
      los extremos ("…punto es." -> "….es") ni las comas/punto y coma de las
      pausas del dictado ("CONTACTO, ARROBA NOVA digital.es");
    - el dominio pierde los espacios (un dominio no puede tenerlos) y las
      tildes que añade el ASR ("mediterráneo" -> "mediterraneo");
    - la parte local con VARIAS palabras es ambigua ("paula sanchez": ¿punto,
      guion bajo o nada?): no se adivina y se deja tal cual.
    Si no se puede normalizar sin adivinar, devuelve el valor original.
    """
    if value is None:
        return None
    original = " ".join(str(value).split())
    if not original:
        return None
    text = _without_accents_keep_enye(original).casefold()
    # Puntuación accidental alrededor (Whisper cierra la frase con un punto, comillas...)
    text = text.strip(" .,;:!?¡¿\"'«»<>()[]")
    # Pausas del dictado transcritas como comas o punto y coma ("CONTACTO, ARROBA NOVA digital.es"):
    # un email no puede contenerlas, así que son siempre ruido del ASR
    text = re.sub(r"[,;:]", " ", text)
    # Variantes del ASR: "a roba", "a-roba", "aroba" -> "arroba"; "dot" -> "punto"
    text = re.sub(r"(?<![a-z0-9ñ])a[\s\-]+r?roba\b", "arroba", text)
    text = re.sub(r"(?<![a-z0-9ñ])aroba\b", "arroba", text)
    text = re.sub(r"\bdot\b", "punto", text)
    if "@" not in text:
        if len(re.findall("arroba", text)) != 1:
            return original
        text = text.replace("arroba", " @ ")
    if text.count("@") != 1:
        return original
    for spoken, symbol in _SPOKEN:
        text = re.sub(rf"\b{spoken}\b", f" {symbol} ", text)
    text = re.sub(r"\bpunto\b", " . ", text)
    local, domain = (part.strip() for part in text.split("@"))
    local = re.sub(r"\s*([._\-])\s*", r"\1", local)
    if not local or " " in local:
        return original
    domain = re.sub(r"\s+", "", domain)
    if "." not in domain:
        domain = _GLUED_TLD.sub(r".\1", domain)
    candidate = f"{local}@{domain}"
    return candidate if _EMAIL.fullmatch(candidate) else original


# --- CIF / NIF / NIE ---------------------------------------------------------

_TAX_ID_SEPARATORS = re.compile(r"[\s.\-/]+")
_TAX_ID_PATTERNS = (
    re.compile(r"[ABCDEFGHJKLMNPQRSUVW]\d{7}[0-9A-J]"),    # CIF (persona jurídica)
    re.compile(r"\d{8}[A-Z]"),                            # NIF (DNI)
    re.compile(r"[XYZ]\d{7}[A-Z]"),                       # NIE
)


def is_tax_id(value: str | None) -> bool:
    return bool(value) and any(p.fullmatch(value) for p in _TAX_ID_PATTERNS)


def normalize_tax_id(value: str | None) -> str | None:
    """"B 54 321 678" / "b-54321678" -> "B54321678" si encaja con CIF, NIF o NIE; si no, tal cual."""
    if value is None:
        return None
    original = " ".join(str(value).split())
    if not original:
        return None
    candidate = _TAX_ID_SEPARATORS.sub("", _strip_accents(original)).upper()
    return candidate if is_tax_id(candidate) else original


__all__ = ["normalize_phone", "phone_review_message", "normalize_email", "normalize_tax_id", "is_tax_id"]
