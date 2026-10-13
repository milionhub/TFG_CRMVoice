"""
Ventas del comercial autenticado (H.2). Privadas: nadie ve, edita ni borra
las de otro (404 igual que si no existieran). Rutas finas: la validación y
la escritura están en services/writes/sales.py.
"""
from typing import Optional

from fastapi import APIRouter, Depends, Query, Response, status

from api.deps import get_current_user
from db import connection
from schemas.crm import SaleCreate, SaleUpdate
from services.writes import sales as sale_writes

router = APIRouter(tags=["sales"])

_DATE = r"^\d{4}-\d{2}-\d{2}$"


@router.get("/sales")
def get_sales(
    client_id: Optional[int] = Query(None),
    date_from: Optional[str] = Query(None, alias="from", pattern=_DATE),
    date_to: Optional[str] = Query(None, alias="to", pattern=_DATE),
    current_user: dict = Depends(get_current_user),
):
    with connection() as conn:
        sales = sale_writes.list_sales(conn, current_user["user_id"], client_id=client_id,
                                       date_from=date_from, date_to=date_to)
    return {"count": len(sales), "sales": sales}


@router.post("/sales", status_code=status.HTTP_201_CREATED)
def create_sales(body: SaleCreate, current_user: dict = Depends(get_current_user)):
    sales = sale_writes.create_sales(body, current_user["user_id"])
    return {"ids": [s["id"] for s in sales], "sales": sales}


@router.put("/sales/{sale_id}")
def update_sale(sale_id: int, body: SaleUpdate, current_user: dict = Depends(get_current_user)):
    return sale_writes.update_sale(sale_id, body, current_user["user_id"])


@router.delete("/sales/{sale_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_sale(sale_id: int, current_user: dict = Depends(get_current_user)):
    sale_writes.delete_sale(sale_id, current_user["user_id"])
    return Response(status_code=status.HTTP_204_NO_CONTENT)
