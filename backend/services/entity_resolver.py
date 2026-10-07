"""
Resolución de entidades del CRM: del texto dictado a clientes, contactos,
productos y tipos de actividad reales.

Clientes y contactos: primero coincidencia exacta (normalizada), después
fuzzy (RapidFuzz). Si dos candidatos quedan igual de bien situados no se
elige ninguno: el resultado es "ambiguous". match_client / match_contact
devuelven el detalle; resolve_client / resolve_contact mantienen la firma
(id | None, score) que usan el pipeline de voz y el chat.

Política de confianza (I.7), de más a menos fuerte. Un id solo sale de los
niveles 1-4 y nunca se elige ante una ambigüedad real:
  1. selección explícita del usuario (la aplica el Action Engine al editar);
  2. coincidencia exacta normalizada (razón social con o sin forma jurídica,
     alias; contacto por nombre completo o de pila);
  3. inferencia relacional inequívoca: sin cliente dicho, el de un contacto
     inequívoco ("inherited");
  4. coincidencia aproximada fuerte: fuzzy único con margen ("fuzzy") o
     reforzada por el contexto ("contextual", _contextual_pair): las
     menciones de cliente y contacto, juntas, señalan UNA sola pareja;
  5. varios candidatos -> "ambiguous" (revisión);
  6. evidencia insuficiente -> "unresolved" (o "conflict" si se contradice).
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

# Un cliente heredado del contacto no se ha dicho: vale el score del
# contacto con este descuento
INHERITED_CLIENT_FACTOR = 0.9

# Nivel 4 (contextual): parecido mínimo entre el cliente dicho y el cliente
# del contacto con la métrica robusta a la segmentación del ASR. Más exigente
# que FUZZY_THRESHOLD y solo cuenta si OTRA evidencia (el contacto) lo respalda
CONTEXT_CLIENT_THRESHOLD = 85

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


def normalize_client_name(name: str | None) -> str:
    """Clave para comparar nombres de cliente: normalizado y sin forma jurídica ("Rivera S.L." -> "rivera")."""
    return _strip_legal_suffix(normalize_text(name or ""))


def _client_names(row) -> dict:
    """Formas normalizadas con las que se puede nombrar al cliente -> texto original."""
    razon = normalize_text(row["razon_social"])
    names = {razon: row["razon_social"], _strip_legal_suffix(razon): row["razon_social"]}
    if row["alias"]:
        names[normalize_text(row["alias"])] = row["alias"]
    return {n: original for n, original in names.items() if n}


def context_client_score(mention_norm: str, row) -> float:
    """
    Parecido robusto a los errores de segmentación del ASR, que parte o junta
    palabras ("Institutos Alucas" ~ "Instituto San Lucas"): el mejor de
    token_sort_ratio, ratio y ratio sin espacios contra cada forma del cliente.
    SOLO para el nivel 4 (contextual): por sí solo nunca resuelve un cliente.
    """
    compact = mention_norm.replace(" ", "")
    return max(max(fuzz.token_sort_ratio(mention_norm, n), fuzz.ratio(mention_norm, n),
                   fuzz.ratio(compact, n.replace(" ", "")))
               for n in _client_names(row))


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


# =====================================================================
# Contactos
# =====================================================================

def _load_contacts(client_id=None):
    conn = get_connection()
    try:
        if client_id:
            return conn.execute(
                "SELECT id, nombre, client_id FROM contacts WHERE client_id = ? ORDER BY id", (client_id,)
            ).fetchall()
        return conn.execute("SELECT id, nombre, client_id FROM contacts ORDER BY id").fetchall()
    finally:
        conn.close()


def _contact_scores(contact_norm: str, client_id: int | None = None):
    """(coincidencias del nombre completo, del nombre de pila, todos con su score fuzzy)."""
    full_matches, first_name_matches, scored = [], [], []

    for c in _load_contacts(client_id):
        nombre_norm = normalize_text(c["nombre"])
        if not nombre_norm:
            continue
        first_name = nombre_norm.split()[0]
        candidate = {"id": c["id"], "name": c["nombre"], "client_id": c["client_id"]}

        if contact_norm == nombre_norm:
            full_matches.append({**candidate, "score": 100.0})
        elif contact_norm == first_name:
            first_name_matches.append({**candidate, "score": 100.0})

        # Parecido con el nombre completo y con solo el nombre de pila
        score = max(fuzz.token_sort_ratio(contact_norm, nombre_norm), fuzz.ratio(contact_norm, first_name))
        scored.append({**candidate, "score": score})

    return full_matches, first_name_matches, scored


def match_contact(contacto_raw: str, client_id: int | None = None) -> dict:
    """Contacto del CRM (del cliente indicado, si lo hay) que corresponde al nombre extraído."""
    contact_norm = normalize_text(contacto_raw)

    if not contact_norm:
        return _result("unresolved")

    full_matches, first_name_matches, scored = _contact_scores(contact_norm, client_id)
    return _decide(full_matches or first_name_matches, scored, FUZZY_THRESHOLD)


def _plausible(exact: list, scored: list, threshold: float) -> list:
    """TODOS los candidatos que _decide tendría en cuenta (sin el tope de MAX_CANDIDATES)."""
    if exact:
        return exact
    ranked = [c for c in scored if c["score"] >= threshold]
    if not ranked:
        return []
    best = max(c["score"] for c in ranked)
    return [c for c in ranked if best - c["score"] < AMBIGUITY_MARGIN]


def _contextual_pair(cliente_raw: str, contacto_raw: str):
    """
    Nivel 4 de la política: el cliente dicho NO se resuelve solo (no existe o
    es ambiguo), pero junto con el contacto dicho señala una única pareja.

    - Contactos plausibles: los que match_contact tendría en cuenta (exactos,
      o fuzzy dentro del margen del mejor), en TODO el CRM.
    - Clientes plausibles: los que match_client dejaría como ambiguos (fuzzy
      dentro del margen) y los que superan CONTEXT_CLIENT_THRESHOLD con la
      métrica robusta al ASR quedando dentro del margen del mejor.
    - Pareja: contacto plausible cuyo cliente es un cliente plausible.
      Exactamente una -> (cliente, contacto, contacto_único); si no, None.

    Nunca elige "la mejor" entre varias parejas: eso sigue siendo una
    ambigüedad para el usuario. Las listas no tienen tope (MAX_CANDIDATES):
    la unicidad se comprueba sobre todos los candidatos.
    """
    client_norm, contact_norm = normalize_text(cliente_raw), normalize_text(contacto_raw)
    if not client_norm or not contact_norm:
        return None

    full_matches, first_name_matches, scored = _contact_scores(contact_norm)
    contacts = _plausible(full_matches or first_name_matches, scored, FUZZY_THRESHOLD)
    if not contacts:
        return None

    textual, context = [], {}
    for row in _load_clients():
        candidate = {"id": row["id"], "name": row["razon_social"]}
        textual.append({**candidate, "score": max(fuzz.token_sort_ratio(client_norm, n)
                                                  for n in _client_names(row))})
        context[row["id"]] = {**candidate, "score": context_client_score(client_norm, row)}
    clients = {c["id"]: c for c in _plausible([], list(context.values()), CONTEXT_CLIENT_THRESHOLD)}
    for c in _plausible([], textual, FUZZY_THRESHOLD):
        clients.setdefault(c["id"], context[c["id"]])

    pairs = [(clients[k["client_id"]], k) for k in contacts if k["client_id"] in clients]
    if len(pairs) != 1:
        return None
    client, contact = pairs[0]
    return client, contact, len(contacts) == 1


def resolve_contact(contacto_raw: str, client_id: int | None = None):
    """(contact_id | None, score). None también si el nombre es ambiguo."""
    match = match_contact(contacto_raw, client_id)
    return match["id"], match["score"]


def _contact_client(contact_id: int):
    """(client_id, razón social) del contacto."""
    conn = get_connection()
    try:
        row = conn.execute("""
            SELECT c.id, c.razon_social
            FROM contacts ct
            JOIN clients c ON c.id = ct.client_id
            WHERE ct.id = ?
        """, (contact_id,)).fetchone()
    finally:
        conn.close()
    return (row["id"], row["razon_social"]) if row else (None, None)


def resolve_client_and_contact(cliente_raw: str | None, contacto_raw: str | None) -> dict:
    """
    Resolución contextual cliente↔contacto (F.2), común al Action Engine y
    a las herramientas del chat:
    - con cliente resuelto, el contacto se busca solo dentro de ese cliente;
      si existe pero en otro cliente, el contacto queda en "conflict";
    - sin cliente dicho, un contacto inequívoco aporta su cliente ("inherited");
    - un cliente dicho que no existe no se sustituye por el del contacto: "conflict",
      salvo que las dos menciones juntas señalen una única pareja (nivel 4,
      "contextual": _contextual_pair).

    client: {id, raw, status, origin, score, candidates}; `raw` es el nombre
    dicho o, si se hereda, la razón social del contacto. Los candidatos del
    cliente solo se exponen si se dijo. contact: {id, status, score, candidates}.
    """
    client_match = match_client(cliente_raw)
    client_id = client_match["id"]
    client_status = client_match["status"]
    client_score = client_match["score"]
    client_origin = "detected" if cliente_raw else None

    contact_match = match_contact(contacto_raw, client_id)
    contact_status = contact_match["status"]
    contact_candidates = contact_match["candidates"]

    if cliente_raw and contacto_raw and client_status in ("unresolved", "ambiguous"):
        # Nivel 4: el cliente dicho no basta por sí solo; ¿lo deja inequívoco el contacto dicho?
        pair = _contextual_pair(cliente_raw, contacto_raw)
        if pair is not None:
            client, contact, contact_unique = pair
            client_id, client_status, client_score = client["id"], "contextual", client["score"]
            client_match = {**client_match, "candidates": [client]}
            if not contact_unique:
                contact_status = "contextual"
            contact_match = {**contact_match, "id": contact["id"], "score": contact["score"]}
            contact_candidates = [contact]

    if client_id and contacto_raw and contact_status == "unresolved":
        # ¿Existe, pero en otro cliente? Conflicto: no se asocia
        elsewhere = match_contact(contacto_raw)
        if elsewhere["status"] != "unresolved":
            contact_status = "conflict"
            contact_candidates = elsewhere["candidates"]

    contact_id = contact_match["id"]

    if contact_id and not cliente_raw:
        # No se dijo cliente y el contacto es inequívoco: se hereda el suyo
        client_id, cliente_raw = _contact_client(contact_id)
        if client_id:
            client_status = "inherited"
            client_origin = "inherited"
            client_score = contact_match["score"] * INHERITED_CLIENT_FACTOR

    elif contact_id and client_status == "unresolved":
        # Se dijo un cliente que no existe y el contacto es de otro: conflicto
        client_status = "conflict"

    return {
        "client": {
            "id": client_id,
            "raw": cliente_raw,
            "status": client_status,
            "origin": client_origin,
            "score": client_score,
            "candidates": client_match["candidates"] if client_origin == "detected" else [],
        },
        "contact": {
            "id": contact_id,
            "status": contact_status,
            "score": contact_match["score"],
            "candidates": contact_candidates,
        },
    }


# =====================================================================
# Productos
# =====================================================================

def _numbers(tokens) -> list[str]:
    return [t for t in tokens if _NUMBER.fullmatch(t)]


def _phrase_score(tokens: list[str], phrase: list[str], model_numbers: set[str]) -> float:
    return _phrase_match(tokens, phrase, model_numbers)[0]


def _phrase_match(tokens: list[str], phrase: list[str], model_numbers: set[str]) -> tuple[float, str | None]:
    """
    Mejor similitud entre el nombre/alias del producto y una ventana del texto
    del mismo número de palabras, y esa ventana (normalizada). Los números de
    modelo deben coincidir:
    - si el nombre/alias tiene números, la ventana debe tener exactamente esos;
    - si no los tiene (alias de familia, "monitor vela"), el número que venga
      justo detrás debe ser uno de los modelos del producto.
    """
    n = len(phrase)
    phrase_text = " ".join(phrase)
    phrase_numbers = _numbers(phrase)
    best, best_window = 0.0, None

    for i in range(len(tokens) - n + 1):
        window = tokens[i:i + n]

        if _numbers(window) != phrase_numbers:
            continue

        following = tokens[i + n] if i + n < len(tokens) else None
        if (not phrase_numbers and model_numbers and following
                and _NUMBER.fullmatch(following) and following not in model_numbers):
            continue

        score = fuzz.ratio(" ".join(window), phrase_text)
        if score > best:
            best, best_window = score, " ".join(window)

    return best, best_window


def resolve_products(text: str):
    """
    Detecta múltiples productos mencionados en el texto.
    Devuelve lista de dicts con:
    - product_id
    - product_raw
    - confidence
    - said: la ventana del texto que coincidió (normalizada)
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

        score, said = _phrase_match(tokens, phrase, model_numbers.get(product_id, set()))

        if score >= PRODUCT_THRESHOLD and (
                product_id not in unique or score > unique[product_id]["confidence"]):
            unique[product_id] = {
                "product_id": product_id,
                "product_raw": raw,
                "confidence": score,
                "said": said,
            }

    return list(unique.values())
