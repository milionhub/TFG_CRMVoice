def detect_intent(message: str):

    text = message.lower()

    if any(word in text for word in [
        "facturación",
        "factura",
        "facturado",
        "ingresos",
        "ventas"
    ]):
        return "billing_query"

    if any(word in text for word in [
        "resumen",
        "estado cliente",
        "información cliente",
        "situación cliente",
        "como va cliente",
        "como esta",
        "cómo esta"
    ]):
        return "client_summary"

    if any(word in text for word in [
        "reunión",
        "preparar reunión",
        "briefing",
        "reunion",
        "preparar reunion"
    ]):
        return "prepare_meeting"

    if any(word in text for word in [
        "buscar",
        "hablado",
        "sobre",
        "comentamos"
    ]):
        return "semantic_search"


    if any(word in text for word in [
        "insights",
        "análisis clientes",
        "estado clientes",
        "situación clientes"
    ]):
        return "crm_insights"
    
    if any(word in text for word in [
        "analiza cliente",
        "analizar cliente",
        "análisis cliente",
        "analisis cliente"
    ]):
        return "client_analysis"
    
    if any(word in text for word in [
        "facturación",
        "factura",
        "facturado",
        "ingresos",
        "ventas",
        "cuánto factura",
        "cuanto factura"
    ]):
        return "billing_query"
    
    if any(word in text for word in [
        "oportunidades",
        "potencial",
        "upsell",
        "cross sell"
    ]):
        return "client_opportunities"



    return "general"


