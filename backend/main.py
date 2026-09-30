# config carga backend/.env (una sola vez)
import config

# Antes de importar nada más: error claro si falta configuración obligatoria
from env_check import check_required_env
check_required_env()

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from db import init_db
from api.routers import (
    activities as activities_router,
    auth as auth_router,
    chat as chat_router,
    crm as crm_router,
    system as system_router,
    voice as voice_router,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # La BD se inicializa al arrancar la aplicación (no al importar main)
    init_db()
    yield


app = FastAPI(
    title="CRM Voice API",
    version="0.3.0",
    description="Backend del TFG CRM Voice",
    lifespan=lifespan,
)

# -------------------------
# CORS
# -------------------------
app.add_middleware(
    CORSMiddleware,
    allow_origins=config.cors_origins(),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(system_router.router)
app.include_router(auth_router.router)
app.include_router(crm_router.router)
app.include_router(activities_router.router)
app.include_router(voice_router.router)
app.include_router(chat_router.router)
