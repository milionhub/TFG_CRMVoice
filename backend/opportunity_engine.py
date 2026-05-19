def detect_opportunities(context):

    insights = []

    total_activities = context["total_activities"]
    billing = context["billing"]

    total_facturado = billing["total_facturado"]
    ticket_medio = billing["ticket_medio"]

    # ----------------------------
    # Mucha actividad pero poca facturación
    # ----------------------------

    if total_activities > 10 and total_facturado < 2000:
        insights.append(
            "Alta actividad comercial pero baja facturación. Puede existir una oportunidad de conversión o upsell."
        )

    # ----------------------------
    # Cliente estratégico
    # ----------------------------

    if total_facturado > 20000:
        insights.append(
            "Cliente estratégico por volumen de facturación. Priorizar seguimiento y fidelización."
        )

    # ----------------------------
    # Ticket medio bajo
    # ----------------------------

    if ticket_medio < 200 and total_facturado > 0:
        insights.append(
            "Ticket medio bajo. Existe potencial para estrategias de upsell o cross-selling."
        )

    return insights
