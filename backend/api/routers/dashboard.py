"""Métricas de Home (H.5.2): solo las del comercial autenticado."""
from fastapi import APIRouter, Depends

from api.deps import get_current_user
from services.dashboard import dashboard

router = APIRouter(tags=["dashboard"])


@router.get("/dashboard")
def get_dashboard(current_user: dict = Depends(get_current_user)):
    return dashboard(current_user["user_id"])
