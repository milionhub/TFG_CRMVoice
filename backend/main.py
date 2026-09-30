# config carga backend/.env (una sola vez)
import config

# Antes de importar nada más: error claro si falta configuración obligatoria
from env_check import check_required_env
check_required_env()

import re

from fastapi import FastAPI, Depends
from fastapi.middleware.cors import CORSMiddleware

from db import init_db
from entity_resolver import resolve_client
from openai_service import generate_meeting_summary, format_billing_response, generate_client_summary, generate_account_analysis
from context_service import build_context, get_client_billing_summary
from semantic_search_service import semantic_search_activities
from api.deps import get_current_user
from api.routers import (
    activities as activities_router,
    auth as auth_router,
    crm as crm_router,
    system as system_router,
    voice as voice_router,
)
from schemas.chat import ChatRequest, ChatResponse, PrepareMeetingRequest
from chat_memory import set_last_client, get_last_client, set_pending_intent, get_pending_intent, clear_pending_intent
from client_detection_service import detect_client_from_message
from intent_service import detect_intent
from crm_insights_service import get_crm_insights
from opportunity_engine import detect_opportunities
from ai_router import analyze_user_message

app = FastAPI(
    title="CRM Voice API",
    version="0.3.0",
    description="Backend del TFG CRM Voice",
)

init_db()

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

# Routers ya separados por dominio (el resto de endpoints sigue aquí de momento)
app.include_router(system_router.router)
app.include_router(auth_router.router)
app.include_router(crm_router.router)
app.include_router(activities_router.router)
app.include_router(voice_router.router)

def prepare_meeting_by_client_id(client_id: int, salesperson_id: int):

    context_data = build_context(client_id, salesperson_id)

    if not context_data:
        return None, "Cliente no encontrado"

    try:
        summary = generate_meeting_summary(context_data)
    except Exception as e:
        return None, f"Error generando resumen: {str(e)}"

    return summary, None

@app.post("/prepare-meeting")
def prepare_meeting(request: PrepareMeetingRequest, current_user: dict = Depends(get_current_user)):

    context_data = build_context(request.client_id, current_user["user_id"])

    if not context_data:
        return {"error": "Cliente no encontrado"}

    try:
        summary = generate_meeting_summary(context_data)
    except Exception as e:
        return {"error": f"Error generando resumen: {str(e)}"}

    return {
        "client_id": request.client_id,
        "meeting_preparation": summary
    }

@app.post("/chat", response_model=ChatResponse)
def chat_endpoint(payload: ChatRequest, current_user: dict = Depends(get_current_user)  ):
    user_message = payload.message.lower()

    pending = get_pending_intent(current_user["user_id"])

    # 🔥 CASO 1 — hay intención pendiente → NO usar IA
    if pending:
        print("PENDING INTENT:", pending)

        if pending["waiting_for"] == "client":

            client_id, confidence = resolve_client(payload.message)

            if client_id:
                set_last_client(current_user["user_id"], client_id)

                # 🔥 usar intent original
                intent = pending["intent"]

                # limpiar estado
                clear_pending_intent(current_user["user_id"])

                print("RESOLVED CLIENT FROM FOLLOW-UP:", client_id)

                # 👇 IMPORTANTE: NO hay ai_client_name aquí
                ai_client_name = None

            else:
                return ChatResponse(
                    type="error",
                    content="No he podido identificar el cliente. ¿Puedes especificarlo mejor?"
                )

    # 🔥 CASO 2 — NO hay pending → usar IA
    else:

        analysis = analyze_user_message(payload.message)

        intent = analysis.get("intent")
        ai_client_name = analysis.get("client_name")
        confidence = analysis.get("confidence", 0)

        print("AI ANALYSIS:", analysis)

        # fallback
        if not intent or confidence < 60:
            intent = detect_intent(payload.message)

        # normalización
        intent_mapping = {
            "client_analysis": "client_summary"
        }

        if intent in intent_mapping:
            intent = intent_mapping[intent]

        # cliente desde IA
        if ai_client_name:
            client_id_ai, conf_ai = resolve_client(ai_client_name)

            print("AI CLIENT:", ai_client_name, "→", client_id_ai)

            if client_id_ai:
                set_last_client(current_user["user_id"], client_id_ai)

        # fallback cliente antiguo
        else:
            auto_client_id = detect_client_from_message(payload.message)

            if auto_client_id:
                set_last_client(current_user["user_id"], auto_client_id)

    if intent == "prepare_meeting":

        # 🔥 EXTRAER SOLO EL CLIENTE
        match = re.search(r"con (.+)", payload.message, re.IGNORECASE)

        if match:
            client_text = match.group(1).strip()
        else:
            client_text = payload.message

        print("CLIENT_TEXT LIMPIO:", client_text)

        client_id, confidence = resolve_client(client_text)

        print("CLIENT_ID:", client_id, "CONF:", confidence)

        if client_id:
            set_last_client(current_user["user_id"], client_id)
        else:
            client_id = get_last_client(current_user["user_id"])

        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="prepare_meeting",
                waiting_for="client"
            )

            return ChatResponse(
                type="prepare_meeting",
                content="¿Para qué cliente quieres preparar la reunión?"
            )

        summary, error = prepare_meeting_by_client_id(client_id, current_user["user_id"])

        if error:
            return ChatResponse(
                type="prepare_meeting",
                content=error
            )

        return ChatResponse(
            type="prepare_meeting",
            content=summary,
            metadata={
                "client_id": client_id,
                "suggested_actions": [
                    "client_summary",
                    "billing_query",
                    "semantic_search"
                ]
             }
        )

    # --- FACTURACIÓN ---
    if intent == "billing_query":

        # Intentamos extraer nombre después de "de" o "tiene"
        match = re.search(r"(de|tiene)\s+(.+)", payload.message, re.IGNORECASE)

        if match:
            client_text = match.group(2).strip()
        else:
            # Si no hay patrón claro, usamos todo el mensaje
            client_text = payload.message

        client_id, confidence = resolve_client(client_text)

        if client_id:
            set_last_client(current_user["user_id"], client_id)

        if not client_id:

            client_id = get_last_client(current_user["user_id"])

        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="billing_query",
                waiting_for="client"
            )

            return ChatResponse(
                type="billing_query",
                content="¿De qué cliente quieres consultar la facturación?"
            )

        billing = get_client_billing_summary(client_id)

        return ChatResponse(
            type="billing_summary",
            content="Resumen de facturación",
            metadata={
                "client_id": client_id,
                "billing": billing,
                "suggested_actions": [
                    "client_summary",
                    "prepare_meeting",
                    "semantic_search"
                ]
            }
        )


    # --- RESUMEN CLIENTE ---
    if intent == "client_summary":

        match = re.search(r"cliente (.+)", payload.message, re.IGNORECASE)

        if match:
            client_text = match.group(1).strip()

        if not match:

            set_pending_intent(
                current_user["user_id"],
                intent="client_summary",
                waiting_for="client"
            )

            return ChatResponse(
                type="client_summary",
                content="¿De qué cliente quieres el resumen?"
            )

        client_id, confidence = resolve_client(client_text)

        if client_id:
            set_last_client(current_user["user_id"], client_id)

        if not client_id:

            client_id = get_last_client(current_user["user_id"])

        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="client_summary",
                waiting_for="client"
            )

            return ChatResponse(
                type="client_summary",
                content=f"No he podido identificar el cliente '{client_text}'. ¿Puedes especificarlo mejor?"
            )

        context = build_context(client_id, current_user["user_id"])


        summary_text = generate_client_summary(context)

        short_status = summary_text.split("\n")[0] 

        # 🔹 separar oportunidades (ya lo tienes)
        opportunities = detect_opportunities(context)

        return ChatResponse(
            type="client_summary",
            content="Resumen cliente",
            metadata={
                "client_id": client_id,
                "client_name": context["client_name"],

                # 🔥 AQUÍ ESTÁ LA CLAVE
                "summary": {
                    "status": (
                        "Cliente activo"
                        if context["total_activities"] > 3
                        else "Cliente con baja actividad"
                    ),
                    "activity": f"{context['total_activities']} actividades registradas",
                    "opportunities": opportunities or []
                },

                "suggested_actions": [
                    "billing_query",
                    "prepare_meeting",
                    "semantic_search"
                ]
            }
        )

    
    # --- CONTEXTO CLIENTE ---
    if "contexto" in user_message:
        return ChatResponse(
            type="client_context",
            content="Buscando contexto del cliente..."
        )

    # --- BÚSQUEDA SEMÁNTICA ---
    if intent == "semantic_search":

        # Intentamos detectar cliente en el mensaje completo
        client_id, confidence = resolve_client(payload.message)

        if client_id:
            results = semantic_search_activities(payload.message, current_user["user_id"], client_id=client_id)
        else:
            results = semantic_search_activities(payload.message, current_user["user_id"])

        

        return ChatResponse(
            type="semantic_search",
            content=f"Resultados encontrados",
            metadata={
                "results": results,
                "suggested_actions": [
                    "client_summary",
                    "billing_query",
                    "prepare_meeting"
                ]
            }
        )


    # --- CRM INSIGHTS ---
    if intent == "crm_insights":

        insights = get_crm_insights(current_user["user_id"])
        activity_insights = insights.get("activity_insights", [])
        activity_text = "\n".join(f"- {a}" for a in activity_insights)


        top_clients = "\n".join(
            f"- {c['razon_social']}"
            for c in insights["top_clients"]
        )

        inactive_clients = "\n".join(
            f"- {c['razon_social']}"
            for c in insights["inactive_clients"]
        )

        content = f"""
    📊 Insights del CRM

    Clientes con mayor facturación:
    {top_clients}

    Clientes sin actividad reciente:
    {inactive_clients}

    Actividad comercial detectada:
    {activity_text}
    """

        return ChatResponse(
            type="crm_insights",
            content=content,
            metadata={
                "suggested_actions": [
                    "client_summary",
                    "billing_query",
                    "semantic_search"
                ]
            }
        )


    # --- ANÁLISIS COMPLETO DE CLIENTE ---
    if intent == "client_analysis":

        client_id, confidence = resolve_client(payload.message)

        if client_id:
            set_last_client(current_user["user_id"], client_id)

        if not client_id:
            client_id = get_last_client(current_user["user_id"])
        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="client_analysis",
                waiting_for="client"
            )

            return ChatResponse(
                type="client_analysis",
                content="¿Qué cliente quieres analizar?"
            )

        context = build_context(client_id, current_user["user_id"])

        opportunities = detect_opportunities(context)

        analysis = generate_account_analysis(context)

        if opportunities:

            analysis += "\n\n📈 Insights automáticos detectados:\n"

            for o in opportunities:
                analysis += f"- {o}\n"

        return ChatResponse(
            type="client_analysis",
            content=analysis,
            metadata={
                "client_id": client_id,
                "suggested_actions": [
                    "billing_query",
                    "prepare_meeting",
                    "semantic_search"
                ]
        }
        )

    # --- OPORTUNIDADES CLIENTE ---
    if intent == "client_opportunities":

        client_id, confidence = resolve_client(payload.message)

        if client_id:
            set_last_client(current_user["user_id"], client_id)

        if not client_id:
            client_id = get_last_client(current_user["user_id"])

        if not client_id:

            set_pending_intent(
                current_user["user_id"],
                intent="client_opportunities",
                waiting_for="client"
            )

            return ChatResponse(
                type="client_opportunities",
                content="¿De qué cliente quieres ver oportunidades?"
            )
        context = build_context(client_id, current_user["user_id"])

        opportunities = detect_opportunities(context)

        if not opportunities:
            content = "No se han detectado oportunidades claras en este cliente."
        else:
            content = "📈 Oportunidades detectadas:\n\n"
            for o in opportunities:
                content += f"- {o}\n"

        return ChatResponse(
            type="client_opportunities",
            content=content,
            metadata={
                "client_id": client_id
            }
        )


    # --- DEFAULT ---
    return ChatResponse(
        type="error",
        content=f"No he entendido la petición. Prueba de nuevo."
    )
