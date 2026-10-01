// Estado vacío: qué puede consultar el usuario y seis ejemplos. Un ejemplo
// envía exactamente su texto por el camino normal (sin lógica especial).
import 'package:flutter/material.dart';

import 'chat_theme.dart';

class StarterPrompt {
  final String category;
  final String text;

  const StarterPrompt(this.category, this.text);
}

class ChatEmptyState extends StatelessWidget {
  static const title = "¿Qué quieres consultar?";
  static const helper =
      "Pregunta en lenguaje natural sobre tus clientes, actividades y productos. "
      "CRMVoice IA consulta los datos de tu CRM sin modificarlos.";

  static const prompts = [
    StarterPrompt("Clientes", "¿Cómo va Rivera?"),
    StarterPrompt("Agenda", "¿Qué tengo mañana?"),
    StarterPrompt("Actividad", "¿Qué hice la semana pasada?"),
    StarterPrompt("Productos", "¿Con qué clientes he hablado del Ratón Faro?"),
    StarterPrompt("Preparación", "Prepárame para una reunión con San Lucas"),
    StarterPrompt("Prioridades", "¿Qué clientes debería revisar?"),
  ];

  final ValueChanged<String> onSelected;
  final bool enabled;

  const ChatEmptyState({super.key, required this.onSelected, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final columns = screenWidth >= 1200 ? 3 : (screenWidth >= 800 ? 2 : 1);
    const gap = 12.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600, color: ChatColors.textPrimary)),
        const SizedBox(height: 8),
        const Text(helper, style: TextStyle(fontSize: 14.5, height: 1.5, color: ChatColors.textSecondary)),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final prompt in prompts)
                  SizedBox(
                    width: cardWidth,
                    child: _StarterCard(prompt: prompt, onTap: enabled ? () => onSelected(prompt.text) : null),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StarterCard extends StatelessWidget {
  final StarterPrompt prompt;
  final VoidCallback? onTap;

  const _StarterCard({required this.prompt, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: "Preguntar: ${prompt.text}",
      // excludeSemantics oculta la acción del InkWell: se expone aquí
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: ChatColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ChatLayout.radius),
          side: const BorderSide(color: ChatColors.border),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ChatLayout.radius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 76),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(prompt.category.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 11, letterSpacing: 0.6, fontWeight: FontWeight.w600, color: ChatColors.accent)),
                  const SizedBox(height: 6),
                  Text(prompt.text, style: const TextStyle(fontSize: 14.5, height: 1.4, color: ChatColors.textPrimary)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
