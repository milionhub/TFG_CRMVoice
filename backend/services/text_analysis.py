"""
Análisis del texto dictado con reglas (regex): cliente, contacto, acción y fecha.

Es lo que devuelve /process-text y el primer paso de /process-audio.

Cliente y contacto se extraen tras un conector ("de", "empresa", "con",
"a"...). Si el texto no los tiene (o viene en minúsculas), se buscan en el
catálogo los nombres exactos de clientes y contactos.
"""
import re

from services import entity_resolver
from services.date_resolver import resolve_relative_date

# Una palabra que empieza por mayúscula (nombre propio)
_CAP = r"[A-ZÁÉÍÓÚÑ][A-Za-zÁÉÍÓÚÑáéíóúñü]*"

# Palabras que nunca forman parte de un nombre de cliente o de persona,
# aunque aparezcan con mayúscula (inicio de frase, dictado...)
_NOT_A_NAME = {
    "hoy", "manana", "ayer", "pasado", "tarde", "noche", "semana", "lunes", "martes", "miercoles",
    "jueves", "viernes", "sabado", "domingo", "enero", "febrero", "marzo", "abril", "mayo", "junio",
    "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre", "para", "por", "sobre",
    "llamar", "llame", "llamada", "enviar", "envie", "mandar", "concertar", "reunion", "reunirme",
    "visita", "visitar", "visite", "presentar", "hablar", "hacer", "enseñar", "ensenar", "seguimiento",
    "presupuesto", "oferta", "cliente", "empresa",
}

# Conectores en minúscula que pueden ir dentro de un nombre ("Ayuntamiento de Villademo")
_NAME_CONNECTORS = r"(?:de|del|la|las|los|y)"

_CLIENT_NAME = rf"{_CAP}(?:\s+{_CAP}|\s+{_NAME_CONNECTORS}\s+{_CAP})*"
_CLIENT_PATTERNS = [
    re.compile(rf"(?i:\b(?:empresa|cliente)\s+)({_CLIENT_NAME})"),
    re.compile(rf"(?i:\bde\s+)({_CLIENT_NAME})"),
]
MAX_CLIENT_WORDS = 5

_PERSON_NAME = rf"{_CAP}(?:\s+{_CAP})?"
_CONTACT_PATTERN = re.compile(rf"(?i:\b(?:con|a|para)\s+)({_PERSON_NAME})")


def normalize_name(name: str) -> str:
    return " ".join(word.capitalize() for word in name.split())


def _trim_name(name: str) -> str | None:
    """Corta el nombre en la primera palabra que no puede formar parte de él."""
    words = []
    for word in name.split():
        if entity_resolver.normalize_text(word) in _NOT_A_NAME:
            break
        words.append(word)

    # Un nombre no termina en conector ("Ayuntamiento de")
    while words and re.fullmatch(_NAME_CONNECTORS, words[-1]):
        words.pop()

    return " ".join(words) or None


def detect_cliente(text: str) -> str | None:
    """
    Detecta empresa tras:
    - de Clínica Horizonte
    - empresa Orion Consultoría
    - cliente Nebula
    """

    for pattern in _CLIENT_PATTERNS:
        for match in pattern.finditer(text):
            candidate = _trim_name(match.group(1))

            # Limitar a pocas palabras (evita capturar frases enteras)
            if candidate and len(candidate.split()) <= MAX_CLIENT_WORDS:
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


def detect_contact(text: str, exclude=()) -> str | None:
    """
    Detecta la persona tras "con", "a" o "para":
    - He hablado con Laura
    - Reunión con Laura Gómez
    - Llamar a Laura

    `exclude`: nombres que no son una persona (p. ej. el cliente detectado).
    """
    excluded = {entity_resolver.normalize_text(e) for e in exclude if e}

    for match in _CONTACT_PATTERN.finditer(text):
        candidate = _trim_name(match.group(1))

        if not candidate:
            continue

        # Todas sus palabras forman parte del nombre de un cliente: no es una persona
        candidate_words = set(entity_resolver.normalize_text(candidate).split())
        if any(candidate_words <= set(e.split()) for e in excluded):
            continue

        return candidate

    return None


def _choose_client(regex_client: str | None, catalog_client: dict) -> str | None:
    """
    "de <X>" no siempre es un cliente: decide el catálogo.
    - X es un cliente (aunque sea ambiguo) -> se conserva;
    - "Nora de Nebula" no es un cliente -> se prueba solo la parte tras el
      último "de"/"del" (el nombre completo solo vale si existe en el catálogo);
    - X es un contacto del catálogo -> no es cliente;
    - si no se resuelve, un cliente nombrado sin ambigüedad en el texto tiene
      prioridad; si no hay ninguno, se conserva X como antes.
    """
    candidate = regex_client

    if candidate and entity_resolver.match_client(candidate)["status"] == "unresolved":
        parts = re.split(r"\s+(?:de|del)\s+", candidate, flags=re.IGNORECASE)
        candidate = parts[-1]

        if entity_resolver.match_client(candidate)["status"] == "unresolved":
            if entity_resolver.match_contact(candidate)["status"] == "exact":
                candidate = None

            # ...salvo que sea parte de X ("Acme Motors" no es el cliente "Acme")
            if catalog_client["status"] == "exact" and not _shares_words(catalog_client["mention"], regex_client):
                return catalog_client["mention"]

    if candidate:
        return candidate

    # Sin conector o en minúsculas: cliente nombrado tal cual en el catálogo
    return catalog_client["mention"]


def _shares_words(a: str | None, b: str | None) -> bool:
    words_a = set(entity_resolver.normalize_text(a).split())
    return bool(words_a & set(entity_resolver.normalize_text(b).split()))


def _is_part_of(name: str | None, others) -> bool:
    """Todas las palabras de `name` forman parte de alguno de `others`."""
    words = set(entity_resolver.normalize_text(name).split())
    return bool(words) and any(words <= set(entity_resolver.normalize_text(o).split()) for o in others if o)


def analyze_text(text: str) -> dict:
    catalog_client = entity_resolver.find_client_in_text(text)
    cliente = _choose_client(detect_cliente(text), catalog_client)

    not_a_person = [cliente, catalog_client["mention"]] + [c["name"] for c in catalog_client["candidates"]]
    contacto = detect_contact(text, exclude=not_a_person)

    if not contacto:
        # "presupuesto de Hugo": tras "de" solo vale un contacto que exista en el catálogo
        contacto = entity_resolver.find_contact_in_text(text, markers=("con", "a", "para", "de"))
        if _is_part_of(contacto, not_a_person):
            contacto = None

    return {
        "cliente": cliente,
        "contacto": contacto,
        "accion": detect_action(text),
        "fecha": resolve_relative_date(text),
        "comentario": text,
    }
