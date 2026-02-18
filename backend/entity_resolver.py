from db import get_connection
from rapidfuzz import fuzz
import unicodedata


def normalize_text(text: str) -> str:
    if not text:
        return ""

    text = text.lower().strip()

    # quitar tildes
    text = ''.join(
        c for c in unicodedata.normalize('NFD', text)
        if unicodedata.category(c) != 'Mn'
    )

    return text


FUZZY_THRESHOLD = 70  # bajamos un poco


def calculate_similarity(a: str, b: str) -> int:
    """
    Combina varias métricas para mejorar matching fonético.
    """
    scores = [
        fuzz.ratio(a, b),
        fuzz.partial_ratio(a, b),
        fuzz.token_sort_ratio(a, b),
        fuzz.token_set_ratio(a, b)
    ]
    return max(scores)


def resolve_client(cliente_raw: str):
    if not cliente_raw:
        return None, 0

    cliente_norm = normalize_text(cliente_raw)

    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("SELECT id, razon_social, alias FROM clients")
    clients = cursor.fetchall()

    best_score = 0
    best_client_id = None

    for c in clients:
        razon = normalize_text(c["razon_social"])
        alias = normalize_text(c["alias"] or "")

        score_razon = fuzz.token_sort_ratio(cliente_norm, razon)
        score_alias = fuzz.token_sort_ratio(cliente_norm, alias)

        score = max(score_razon, score_alias)

        if score > best_score:
            best_score = score
            best_client_id = c["id"]

    conn.close()

    if best_score >= FUZZY_THRESHOLD:
        return best_client_id, best_score

    return None, best_score



def resolve_activity_type(accion_raw: str):
    if not accion_raw:
        return None

    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("SELECT id, accion FROM activity_types")
    types = cursor.fetchall()

    accion_norm = normalize_text(accion_raw)

    for t in types:
        if normalize_text(t["accion"]) == accion_norm:
            conn.close()
            return t["id"]

    conn.close()
    return None

from rapidfuzz import fuzz

def resolve_contact(contacto_raw: str, client_id: int | None = None):
    if not contacto_raw:
        return None, 0

    contact_norm = normalize_text(contacto_raw.strip())

    conn = get_connection()
    cursor = conn.cursor()

    # 🔎 Si tenemos cliente, limitamos búsqueda
    if client_id:
        cursor.execute("""
            SELECT id, nombre 
            FROM contacts 
            WHERE client_id = ?
        """, (client_id,))
    else:
        cursor.execute("""
            SELECT id, nombre 
            FROM contacts
        """)

    contacts = cursor.fetchall()

    best_score = 0
    best_contact_id = None

    for c in contacts:
        nombre_norm = normalize_text(c["nombre"])

        # 🔹 1. Match nombre completo
        score_full = fuzz.token_sort_ratio(contact_norm, nombre_norm)

        # 🔹 2. Match solo primer nombre
        first_name = nombre_norm.split()[0]
        score_first = fuzz.ratio(contact_norm, first_name)

        # 🔹 3. Si contacto_raw es solo nombre y coincide exactamente
        score_exact_first = 100 if contact_norm == first_name else 0

        score = max(score_full, score_first, score_exact_first)

        if score > best_score:
            best_score = score
            best_contact_id = c["id"]

    conn.close()

    if best_score >= FUZZY_THRESHOLD:
        return best_contact_id, best_score

    return None, best_score


