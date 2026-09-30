# chat_memory.py

from typing import Dict, Optional

# user_id -> client_id
_last_client_by_user: Dict[int, int] = {}


def set_last_client(user_id: int, client_id: int):
    _last_client_by_user[user_id] = client_id


def get_last_client(user_id: int) -> Optional[int]:
    return _last_client_by_user.get(user_id)

# 🔥 NUEVO: memoria de intención
_pending_intent_by_user: Dict[int, dict] = {}


def set_pending_intent(user_id: int, intent: str, waiting_for: str):
    _pending_intent_by_user[user_id] = {
        "intent": intent,
        "waiting_for": waiting_for
    }


def get_pending_intent(user_id: int):
    return _pending_intent_by_user.get(user_id)


def clear_pending_intent(user_id: int):
    if user_id in _pending_intent_by_user:
        del _pending_intent_by_user[user_id]