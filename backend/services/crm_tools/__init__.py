"""
Herramientas CRM de solo lectura para el futuro orquestador del chat (G.3).

Contrato común:
- el backend inyecta salesperson_id; nunca lo decide el LLM;
- devuelven dicts JSON serializables y deterministas, con "found" cuando
  una búsqueda normal puede no encontrar nada (nunca se inventan datos);
- argumentos inválidos -> ToolArgumentError; fallos de OpenAI ->
  AIServiceError (G.1); errores de BD o de programación se propagan;
- actividades: solo las del comercial; catálogo y facturación: globales;
- ninguna escribe en el CRM ni llama al LLM (search_activities solo pide
  el embedding de la consulta).
"""
from services.crm_tools._common import TEMPORAL_SCOPES, ToolArgumentError
from services.crm_tools.accounts import get_client_overview, get_contact, prepare_meeting_context
from services.crm_tools.activities import list_activities, search_activities
from services.crm_tools.entities import find_entities
from services.crm_tools.products import get_client_products, search_product_catalog
from services.crm_tools.rankings import METRICS as RANKING_METRICS, crm_rankings
from services.crm_tools.sales import list_sales

__all__ = [
    "RANKING_METRICS", "TEMPORAL_SCOPES", "ToolArgumentError",
    "crm_rankings", "find_entities", "get_client_overview", "get_client_products", "get_contact",
    "list_activities", "list_sales", "prepare_meeting_context", "search_activities", "search_product_catalog",
]
