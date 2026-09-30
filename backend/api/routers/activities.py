"""Actividades del comercial autenticado y búsqueda semántica sobre ellas."""
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from api.deps import get_current_user
from schemas.activities import SemanticSearchRequest
from services import activities

router = APIRouter(tags=["activities"])


@router.get("/activities")
def get_activities(
    client_id: Optional[int] = Query(None),
    action_id: Optional[int] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    current_user: dict = Depends(get_current_user),
):
    return activities.list_activities(
        current_user["user_id"],
        client_id=client_id,
        action_id=action_id,
        date_from=date_from,
        date_to=date_to,
    )


@router.post("/activities")
def create_activity(data: dict, current_user: dict = Depends(get_current_user)):
    # def (no async): FastAPI lo ejecuta en threadpool y la llamada
    # síncrona a OpenAI (embedding) no bloquea el event loop
    return activities.create_activity(data, current_user["user_id"])


@router.post("/semantic-search")
def semantic_search(request: SemanticSearchRequest, current_user: dict = Depends(get_current_user)):
    return activities.semantic_search(request.query, current_user["user_id"])


@router.delete("/activities/{activity_id}")
def delete_activity(activity_id: int, current_user: dict = Depends(get_current_user)):
    try:
        activities.delete_activity(activity_id, current_user["user_id"])
    except activities.ActivityNotFound:
        raise HTTPException(status_code=404, detail="Actividad no encontrada")

    return {"success": True}


@router.put("/activities/{activity_id}")
def update_activity(activity_id: int, data: dict, current_user: dict = Depends(get_current_user)):
    try:
        return activities.update_activity(activity_id, data, current_user["user_id"])
    except activities.ActivityNotFound:
        raise HTTPException(status_code=404, detail="Actividad no encontrada")
