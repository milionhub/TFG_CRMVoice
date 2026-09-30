"""Endpoints públicos de estado de la API."""
from fastapi import APIRouter

router = APIRouter(tags=["system"])


@router.get("/")
def read_root():
    return {"message": "CRM Voice API funcionando 🚀"}


@router.get("/ping")
def ping():
    return {"status": "ok"}
