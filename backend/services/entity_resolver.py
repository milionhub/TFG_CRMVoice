"""
Resolución de entidades del CRM: del texto dictado a clientes, contactos,
productos y tipos de actividad reales.

Clientes y contactos: primero coincidencia exacta (normalizada), después
fuzzy (RapidFuzz). Si dos candidatos quedan igual de bien situados no se
elige ninguno: el resultado es "ambiguous". match_client / match_contact
devuelven el detalle; resolve_client / resolve_contact mantienen la firma
(id | None, score) que usan el pipeline de voz y el chat.
"""
import re
import unicodedata

from rapidfuzz import fuzz

from db import get_connection

FUZZY_THRESHOLD = 70
PRODUCT_THRESHOLD = 85

# Si el segundo candidato queda a menos de estos puntos del primero, el
# resultado es ambiguo (no se elige en silencio)
AMBIGUITY_MARGIN = 5
MAX_CANDIDATES = 3

# Formas jurídicas que no forman parte del nombre por el que se nombra a un cliente
_LEGAL_SUFFIXES = (("s", "l", "u"), ("s", "l"), ("s", "a"), ("slu",), ("sl",), ("sa",))

_NUMBER = re.compile(r"\d+")


def normalize_text(text: str) -> str:
    """Minúsculas, sin tildes, puntuación como espacio y espacios colapsados."""
    if not text:
        return ""

    text = text.casefold()

    # quitar tildes (la ñ queda como n)
    text = ''.join(
        c for c in unicodedata.normalize('NFD', text)
        if unicodedata.category(c) != 'Mn'
    )

    text = re.sub(r"[^\w\s]|_", " ", text)

    return " ".join(text.split())


# =====================================================================
# Resultado de un match
# =====================================================================

def _result(status, best=None, candidates=(), score=0):
    """{id, name, score, status, candidates}: id solo si el match es seguro."""
    return {
        "id": best["id"] if best and status in ("exact", "fuzzy") else None,
        "name": best["name"] if best and status in ("exact", "fuzzy") else None,
        "score": score,
        "status": status,
        "candidates": [dict(c) for c in candidates[:MAX_CANDIDATES]],
    }


def _decide(exact, scored, threshold):
    """
    exact: candidatos con coincidencia exacta; scored: todos con su score fuzzy.
    Candidatos: [{"id", "name", "score"}], ya en orden determinista (por id).
    """
    if exact:
        status = "exact" if len(exact) == 1 else "ambiguous"
        return _result(status, exact[0], exact, 100.0)

    if not scored:
        return _result("unresolved")

    ranked = sorted(scored, key=lambda c: -c["score"])  # estable: a igual score, menor id
    best = ranked[0]

    if best["score"] < threshold:
        return _result("unresolved", score=best["score"])

    close = [c for c in ranked if c["score"] >= threshold and best["score"] - c["score"] < AMBIGUITY_MARGIN]
    status = "fuzzy" if len(close) == 1 else "ambiguous"
    return _result(status, best, close, best["score"])


# =====================================================================
# Clientes
# =====================================================================

def _strip_legal_suffix(name_norm: str) -> str:
    tokens = name_norm.split()
    for suffix in _LEGAL_SUFFIXES:
        if len(tokens) > len(suffix) and tuple(tokens[-len(suffix):]) == suffix:
            return " ".join(tokens[:-len(suffix)])
    return name_norm


def _client_names(row) -> dict:
    """Formas normalizadas con las que se puede nombrar al cliente -> texto original."""
    razon = normalize_text(row["razon_social"])
    names = {razon: row["razon_social"], _strip_legal_suffix(razon): row["razon_social"]}
    if row["alias"]:
        names[normalize_text(row["alias"])] = row["alias"]
    return {n: original for n, original in names.items() if n}


def _load_clients():
    conn = get_connection()
    try:
        return conn.execute("SELECT id, razon_social, alias FROM clients ORDER BY id").fetchall()
    finally:
        conn.close()


def match_client(cliente_raw: str) -> dict:
    """Cliente del CRM que corresponde al nombre extraído del texto."""
    cliente_norm = normalize_text(cliente_raw)

    if not cliente_norm:
        return _result("unresolved")

    exact, scored = [], []

    for c in _load_clients():
        names = _client_names(c)
        candidate = {"id": c["id"], "name": c["razon_social"]}

        if cliente_norm in names:
            exact.append({**candidate, "score": 100.0})

        score = max(fuzz.token_sort_ratio(cliente_norm, n) for n in names)
        scored.append({**candidate, "score": score})

    return _decide(exact, scored, FUZZY_THRESHOLD)


def resolve_client(cliente_raw: str):
    """(client_id | None, score). None también si el nombre es ambiguo."""
    match = match_client(cliente_raw)
    return match["id"], match["score"]


def _contains_phrase(tokens: list[str], phrase: list[str]) -> bool:
    n = len(phrase)
    return any(tokens[i:i + n] == phrase for i in range(len(tokens) - n + 1))


def find_client_in_text(text: str) -> dict:
    """
    Cliente nombrado literalmente en un texto completo (alias o razón social,
    sin distinguir mayúsculas ni tildes). Solo coincidencias exactas de
    palabras completas: nada de fuzzy sobre todo el mensaje.
    Devuelve el resultado de un match más "mention" (el nombre encontrado).
    """
    tokens = normalize_text(text).split()
    found = []  # (longitud de la mención, cliente, texto original)

    for c in _load_clients():
        mentioned = [(len(name), original) for name, original in _client_names(c).items()
                     if len(name) >= 3 and _contains_phrase(tokens, name.split())]
        if mentioned:
            length, original = max(mentioned)
            found.append((length, {"id": c["id"], "name": c["razon_social"], "score": 100.0}, original))

    if not found:
        return {**_result("unresolved"), "mention": None}

    found.sort(key=lambda f: -f[0])  # la mención más larga primero; a igualdad, menor id
    candidates = [f[1] for f in found]
    status = "exact" if len(found) == 1 else "ambiguous"
    return {**_result(status, candidates[0], candidates, 100.0), "mention": found[0][2]}


# =====================================================================
# Contactos
# =====================================================================

def _load_contacts(client_id=None):
    conn = get_connection()
    try:
        if client_id:
            return conn.execute(
                "SELECT id, nombre FROM contacts WHERE client_id = ? ORDER BY id", (client_id,)
            ).fetchall()
        return conn.execute("SELECT id, nombre FROM contacts ORDER BY id").fetchall()
    finally:
        conn.close()


def match_contact(contacto_raw: str, client_id: int | None = None) -> dict:
    """Contacto del CRM (del cliente indicado, si lo hay) que corresponde al nombre extraído."""
    contact_norm = normalize_text(contacto_raw)

    if not contact_norm:
        return _result("unresolved")

    full_matches, first_name_matches, scored = [], [], []

    for c in _load_contacts(client_id):
        nombre_norm = normalize_text(c["nombre"])
        if not nombre_norm:
            continue
        first_name = nombre_norm.split()[0]
        candidate = {"id": c["id"], "name": c["nombre"]}

        if contact_norm == nombre_norm:
            full_matches.append({**candidate, "score": 100.0})
        elif contact_norm == first_name:
            first_name_matches.append({**candidate, "score": 100.0})

        # 🔹 nombre completo y 🔹 solo el nombre de pila
        score = max(fuzz.token_sort_ratio(contact_norm, nombre_norm), fuzz.ratio(contact_norm, first_name))
        scored.append({**candidate, "score": score})

    return _decide(full_matches or first_name_matches, scored, FUZZY_THRESHOLD)


def resolve_contact(contacto_raw: str, client_id: int | None = None):
    """(contact_id | None, score). None también si el nombre es ambiguo."""
    match = match_contact(contacto_raw, client_id)
    return match["id"], match["score"]


def find_contact_in_text(text: str, markers=("con", "a", "para")) -> str | None:
    """
    Contacto del catálogo nombrado en un texto (sin depender de mayúsculas):
    su nombre completo en cualquier posición, o su nombre de pila justo
    después de un marcador ("con", "a", "para"). Devuelve el texto tal como
    aparece en el mensaje; la resolución (y la ambigüedad) es de match_contact.
    """
    tokens = normalize_text(text).split()
    names = [normalize_text(c["nombre"]).split() for c in _load_contacts()]

    positions = []
    for name in names:
        n = len(name)
        for i in range(len(tokens) - n + 1):
            if n > 1 and tokens[i:i + n] == name:
                positions.append((i, n))
            elif i > 0 and tokens[i - 1] in markers and tokens[i] == name[0]:
                positions.append((i, 1))

    if not positions:
        return None

    start, length = min(positions, key=lambda p: (p[0], -p[1]))
    words = re.findall(r"\w+", text)
    # Mismas palabras que los tokens normalizados (la normalización no las une ni separa)
    return " ".join(words[start:start + length]) if len(words) == len(tokens) else " ".join(
        tokens[start:start + length])


# =====================================================================
# Tipos de actividad
# =====================================================================

def resolve_activity_type(accion_raw: str):
    if not accion_raw:
        return None

    conn = get_connection()
    try:
        types = conn.execute("SELECT id, accion FROM activity_types ORDER BY id").fetchall()
    finally:
        conn.close()

    accion_norm = normalize_text(accion_raw)

    for t in types:
        if normalize_text(t["accion"]) == accion_norm:
            return t["id"]

    return None


# =====================================================================
# Productos
# =====================================================================

def _numbers(tokens) -> list[str]:
    return [t for t in tokens if _NUMBER.fullmatch(t)]


def _phrase_score(tokens: list[str], phrase: list[str], model_numbers: set[str]) -> float:
    """
    Mejor similitud entre el nombre/alias del producto y una ventana del texto
    del mismo número de palabras. Los números de modelo deben coincidir:
    - si el nombre/alias tiene números, la ventana debe tener exactamente esos;
    - si no los tiene (alias de familia, "monitor vela"), el número que venga
      justo detrás debe ser uno de los modelos del producto.
    """
    n = len(phrase)
    phrase_text = " ".join(phrase)
    phrase_numbers = _numbers(phrase)
    best = 0.0

    for i in range(len(tokens) - n + 1):
        window = tokens[i:i + n]

        if _numbers(window) != phrase_numbers:
            continue

        following = tokens[i + n] if i + n < len(tokens) else None
        if (not phrase_numbers and model_numbers and following
                and _NUMBER.fullmatch(following) and following not in model_numbers):
            continue

        best = max(best, fuzz.ratio(" ".join(window), phrase_text))

    return best


def resolve_products(text: str):
    """
    Detecta múltiples productos mencionados en el texto.
    Devuelve lista de dicts con:
    - product_id
    - product_raw
    - confidence
    """

    tokens = normalize_text(text).split()

    if not tokens:
        return []

    conn = get_connection()
    try:
        products = conn.execute("SELECT id, nombre FROM products ORDER BY id").fetchall()
        aliases = conn.execute(
            "SELECT product_id, alias FROM product_aliases ORDER BY id"
        ).fetchall()
    finally:
        conn.close()

    # Números de modelo de cada producto (los de su nombre)
    model_numbers = {p["id"]: set(_numbers(normalize_text(p["nombre"]).split())) for p in products}

    # Nombre oficial primero: ante un empate se conserva como product_raw
    phrases = [(p["id"], p["nombre"]) for p in products] + [(a["product_id"], a["alias"]) for a in aliases]

    unique = {}

    for product_id, raw in phrases:
        phrase = normalize_text(raw).split()
        if not phrase:
            continue

        score = _phrase_score(tokens, phrase, model_numbers.get(product_id, set()))

        if score >= PRODUCT_THRESHOLD and (
                product_id not in unique or score > unique[product_id]["confidence"]):
            unique[product_id] = {
                "product_id": product_id,
                "product_raw": raw,
                "confidence": score
            }

    return list(unique.values())
