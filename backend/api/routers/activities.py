"""
Actividades del comercial autenticado (H.2: Activity V2) y búsqueda semántica.

Las rutas son finas: la validación y la escritura están en
services/writes/activities.py. El embedding se genera DESPUÉS de guardar
(best-effort: si OpenAI falla la actividad ya está guardada).

POST y PUT aceptan solo el cuerpo V2 (ActivityIn). Reciben un dict y lo
validan dentro: así la propiedad de la actividad se comprueba antes que el
cuerpo (otro comercial recibe 404, nunca un 422 que delate que existe).
"""
from typing import Literal, Optional

from fastapi import APIRouter, Body, Depends, Query
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from api.deps import get_current_user
from db import connection
from schemas.activities import SemanticSearchRequest
from schemas.crm import ActivityIn, ActivityStatusPatch
from services import activities
from services.writes import current_time, validation_failed
from services.writes import activities as activity_writes

router = APIRouter(tags=["activities"])


def _activity_in(data: dict) -> ActivityIn:
    try:
        return ActivityIn.model_validate(data)
    except ValidationError as error:
        raise validation_failed(error) from None


@router.get("/activities")
def get_activities(
    client_id: Optional[int] = Query(None),
    action_id: Optional[int] = Query(None),
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    status: Optional[Literal["pending", "completed", "cancelled"]] = Query(None),
    current_user: dict = Depends(get_current_user),
):
    return activities.list_activities(
        current_user["user_id"],
        client_id=client_id,
        action_id=action_id,
        date_from=date_from,
        date_to=date_to,
        status=status,
    )


@router.post("/activities")
async def create_activity(data: dict = Body(...), current_user: dict = Depends(get_current_user)):
    user_id, now = current_user["user_id"], current_time()
    activity = _activity_in(data)
    created = await run_in_threadpool(activity_writes.create_activity, activity, user_id, now=now)
    # Después del commit: red fuera de la transacción, sin poder deshacer la actividad
    await run_in_threadpool(activities.ensure_embedding, created["id"])
    return JSONResponse(status_code=201, content=created)


@router.post("/semantic-search")
def semantic_search(request: SemanticSearchRequest, current_user: dict = Depends(get_current_user)):
    return activities.semantic_search(request.query, current_user["user_id"])


@router.delete("/activities/{activity_id}")
def delete_activity(activity_id: int, current_user: dict = Depends(get_current_user)):
    activity_writes.delete_activity(activity_id, current_user["user_id"])
    return {"success": True}


@router.put("/activities/{activity_id}")
async def update_activity(activity_id: int, data: dict = Body(...), current_user: dict = Depends(get_current_user)):
    user_id, now = current_user["user_id"], current_time()

    def current():
        with connection() as conn:
            return dict(activity_writes.owned_activity(conn, activity_id, user_id))   # 404 antes que 422

    row = await run_in_threadpool(current)
    activity = _activity_in(data)
    updated = await run_in_threadpool(activity_writes.update_activity, activity_id, activity, user_id, now=now)
    if activity.comment != row["comentario"]:
        # El servicio ha borrado el embedding obsoleto: se regenera tras el commit
        await run_in_threadpool(activities.ensure_embedding, activity_id)
    return updated


@router.patch("/activities/{activity_id}")
def patch_activity_status(activity_id: int, body: ActivityStatusPatch,
                          current_user: dict = Depends(get_current_user)):
    return activity_writes.set_activity_status(activity_id, body.status, current_user["user_id"])
