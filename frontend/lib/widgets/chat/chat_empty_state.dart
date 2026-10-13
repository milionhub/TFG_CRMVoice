// Estado vacío (I.5.1): símbolo del asistente sobre ondas muy tenues,
// pregunta principal, ayuda, el composer (en escritorio forma parte de la
// composición) y cuatro sugerencias. Una sugerencia envía exactamente su
// texto por el camino normal (sin lógica especial).
//
// Las sugerencias usan capacidades reales del backend: resumen de cliente,
// actividades pendientes de esta semana, ventas registradas de un periodo y
// el ranking «attention» (clientes a revisar).
import 'package:flutter/material.dart';

import '../../core/design/cv_tokens.dart';
import 'chat_identity.dart';
import 'chat_theme.dart';

class StarterPrompt {
  final String category;
  final String text;
  final IconData icon;

  const StarterPrompt(this.category, this.text, this.icon);
}

class ChatEmptyState extends StatelessWidget {
  static const title = "¿Qué quieres saber de tu CRM?";
  static const helper = "Puedo ayudarte a consultar clientes, actividad, agenda, ventas y relaciones comerciales.";

  static const prompts = [
    StarterPrompt("Clientes", "¿Cómo va Tecnología Rivera?", Icons.business_outlined),
    StarterPrompt("Agenda", "¿Qué tengo pendiente esta semana?", Icons.event_note_outlined),
    StarterPrompt("Ventas", "¿Cuánto he vendido este mes?", Icons.trending_up_rounded),
    StarterPrompt("Análisis", "¿Qué clientes debería revisar?", Icons.insights_outlined),
  ];

  final ValueChanged<String> onSelected;
  final bool enabled;

  /// Composer integrado en la composición (escritorio); null en móvil, donde
  /// el composer queda fijo abajo.
  final Widget? composer;

  /// Composición compacta (móvil).
  final bool compact;

  const ChatEmptyState({
    super.key,
    required this.onSelected,
    this.enabled = true,
    this.composer,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Símbolo sobre ondas muy tenues: integrado en el fondo, sin tarjeta
        SizedBox(
          height: compact ? 96 : 128,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ChatWaves(height: compact ? 96 : 128),
              AssistantMark(size: compact ? 46 : 54),
            ],
          ),
        ),
        SizedBox(height: compact ? CvSpace.sm : CvSpace.md),
        Semantics(
          header: true,
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 22 : 28,
              height: 1.25,
              fontWeight: FontWeight.w600,
              letterSpacing: compact ? -0.4 : -0.6,
              color: ChatColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: CvSpace.xs),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              helper,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: compact ? 14.5 : 15.5, height: 1.5, color: ChatColors.textSecondary),
            ),
          ),
        ),
        if (composer != null) ...[
          const SizedBox(height: CvSpace.xxl),
          composer!,
        ],
        SizedBox(height: composer != null ? CvSpace.xl : (compact ? CvSpace.xl : CvSpace.xxl)),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 10.0;
            final columns = constraints.maxWidth >= 560 ? 2 : 1;
            final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final prompt in prompts)
                  SizedBox(
                    width: width,
                    child: SuggestedPrompt(prompt: prompt, onTap: enabled ? () => onSelected(prompt.text) : null),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Sugerencia: icono lineal, categoría, pregunta y flecha sutil. En hover
/// se aclara el borde y la flecha avanza un poco.
class SuggestedPrompt extends StatefulWidget {
  final StarterPrompt prompt;
  final VoidCallback? onTap;

  const SuggestedPrompt({super.key, required this.prompt, required this.onTap});

  @override
  State<SuggestedPrompt> createState() => _SuggestedPromptState();
}

class _SuggestedPromptState extends State<SuggestedPrompt> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    final radius = BorderRadius.circular(ChatLayout.radius);
    const motion = Duration(milliseconds: 160);
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: "Preguntar: ${prompt.text}",
      // excludeSemantics oculta la acción del InkWell: se expone aquí
      onTap: widget.onTap,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: motion,
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: _hover ? CvColors.surfaceHover : CvColors.surface,
          borderRadius: radius,
          border: Border.all(color: _hover ? CvColors.borderHover : CvColors.border),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (h) => setState(() => _hover = h),
            borderRadius: radius,
            hoverColor: Colors.transparent,
            highlightColor: CvColors.primarySoft.withValues(alpha: 0.6),
            splashColor: CvColors.primary.withValues(alpha: 0.10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(CvSpace.sm + 2, CvSpace.sm, CvSpace.sm, CvSpace.sm),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: CvColors.primarySoft,
                        borderRadius: BorderRadius.circular(CvRadius.sm + 1),
                      ),
                      child: Icon(prompt.icon, size: 18, color: CvColors.primaryDark),
                    ),
                    const SizedBox(width: CvSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            prompt.category,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: CvColors.primaryDark,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            prompt.text,
                            style: const TextStyle(fontSize: 14.5, height: 1.35, color: ChatColors.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: CvSpace.xs),
                    AnimatedSlide(
                      duration: motion,
                      curve: Curves.easeOut,
                      offset: _hover ? const Offset(0.15, 0) : Offset.zero,
                      child: AnimatedOpacity(
                        duration: motion,
                        opacity: _hover ? 1 : 0.45,
                        child: const Icon(Icons.arrow_forward_rounded, size: 17, color: CvColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
