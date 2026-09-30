"""Catálogo del CRM (global) y contexto de cliente (actividades del comercial)."""
from typing import Optional

from fastapi import APIRouter, Depends, Query

from api.deps import get_current_user
from services.context import build_context
from services import catalog

router = APIRouter(tags=["crm"])


@router.get("/products")
def get_products(current_user: dict = Depends(get_current_user)):
    return {"products": catalog.list_products()}


@router.get("/clients")
def get_clients(current_user: dict = Depends(get_current_user)):
    return {"clients": catalog.list_clients()}


@router.get("/contacts")
def get_contacts(client_id: Optional[int] = Query(None), current_user: dict = Depends(get_current_user)):
    return {"contacts": catalog.list_contacts(client_id)}


@router.get("/activity-types")
def get_activity_types(current_user: dict = Depends(get_current_user)):
    return {"activity_types": catalog.list_activity_types()}


@router.get("/client-context/{client_id}")
def get_client_context(client_id: int, current_user: dict = Depends(get_current_user)):
    # Actividades solo del comercial autenticado; facturación global (services.context)
    return build_context(client_id, current_user["user_id"])
