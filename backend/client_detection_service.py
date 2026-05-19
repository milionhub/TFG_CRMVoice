from entity_resolver import resolve_client


def detect_client_from_message(message: str):

    client_id, confidence = resolve_client(message)

    if client_id and confidence >= 70:
        return client_id

    return None
