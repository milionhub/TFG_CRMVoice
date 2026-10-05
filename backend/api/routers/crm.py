"""
CRM (H.2): catálogo compartido (productos, clientes, contactos, tipos),
ficha de cliente y altas/ediciones de clientes y contactos.

Clientes y contactos son de TODOS los comerciales: cualquiera los ve y los
edita (el creador solo se guarda como auditoría). Las rutas son finas: la
validación y la escritura están en services/writes.
"""
from typing import Optional

from fastapi import APIRouter, Depends, Query, status

from api.deps import get_current_user
from schemas.crm import ClientIn, ContactIn, ContactUpdate
from services import catalog
from services.client_detail import client_detail
from services.context import build_context
from services.writes import clients as client_writes
from services.writes import contacts as contact_writes

router = APIRouter(tags=["crm"])


@router.get("/products")
def get_products(current_user: dict = Depends(get_current_user)):
    return {"products": catalog.list_products()}


@router.get("/clients")
def get_clients(q: Optional[str] = Query(None, max_length=120), current_user: dict = Depends(get_current_user)):
    return {"clients": catalog.list_clients(q)}


@router.get("/clients/{client_id}")
def get_client_detail(client_id: int, current_user: dict = Depends(get_current_user)):
    return client_detail(client_id, current_user["user_id"])


@router.post("/clients", status_code=status.HTTP_201_CREATED)
def create_client(body: ClientIn, current_user: dict = Depends(get_current_user)):
    return client_writes.create_client(body, current_user["user_id"])


@router.put("/clients/{client_id}")
def update_client(client_id: int, body: ClientIn, current_user: dict = Depends(get_current_user)):
    return client_writes.update_client(client_id, body, current_user["user_id"])


@router.get("/contacts")
def get_contacts(client_id: Optional[int] = Query(None), current_user: dict = Depends(get_current_user)):
    return {"contacts": catalog.list_contacts(client_id)}


@router.post("/contacts", status_code=status.HTTP_201_CREATED)
def create_contact(body: ContactIn, current_user: dict = Depends(get_current_user)):
    return contact_writes.create_contact(body, current_user["user_id"])


@router.put("/contacts/{contact_id}")
def update_contact(contact_id: int, body: ContactUpdate, current_user: dict = Depends(get_current_user)):
    return contact_writes.update_contact(contact_id, body, current_user["user_id"])


@router.get("/activity-types")
def get_activity_types(current_user: dict = Depends(get_current_user)):
    return {"activity_types": catalog.list_activity_types()}


@router.get("/client-context/{client_id}")
def get_client_context(client_id: int, current_user: dict = Depends(get_current_user)):
    # Actividades solo del comercial autenticado; facturación global (services.context)
    return build_context(client_id, current_user["user_id"])
