"""Dependencias FastAPI compartidas por los routers."""
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from core.security import verify_token
from services import accounts

security = HTTPBearer()


def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(security)):

    token = credentials.credentials
    payload = verify_token(token)

    if payload is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token inválido o expirado"
        )

    user_id = payload.get("sub") or payload.get("user_id")

    try:
        user_id = int(user_id)
    except (TypeError, ValueError):
        user_id = None

    # Un JWT bien firmado de un comercial que ya no existe no da acceso
    if not user_id or not accounts.user_exists(user_id):
        raise HTTPException(
            status_code=401,
            detail="Token inválido"
        )

    return {
        "user_id": user_id,
        "email": payload.get("email")
    }
