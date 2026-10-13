// Piezas visuales de la revisión de acciones (I.6.4, Voice V2): cabecera
// con la identidad de onda, transcripción, estado global, filas de «esto se
// guardará», insignias de coincidencia y opciones de candidatos.
//
// Solo presentación: qué se muestra y qué acción dispara cada pieza lo
// decide DraftReview con los datos del borrador del servidor.
import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../chat/chat_identity.dart' show AssistantMark;
import '../ui/cv_feedback.dart';

const _motion = Duration(milliseconds: 180);

/// Etiqueta pequeña en mayúsculas (HAS DICHO, ESTO SE GUARDARÁ...).
class ReviewEyebrow extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const ReviewEyebrow(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              text.toUpperCase(),
              style: CvText.label.copyWith(fontSize: 11.5, letterSpacing: 0.8, color: CvColors.textSecondary),
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Presentación de la revisión: símbolo de CRMVoice, tipo de acción y la
/// promesa de que nada se guarda sin confirmar.
class ReviewIntro extends StatelessWidget {
  final String actionLabel;

  const ReviewIntro({super.key, required this.actionLabel});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AssistantMark(size: 36),
        const SizedBox(width: CvSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: CvColors.primarySoft,
                  borderRadius: BorderRadius.circular(CvRadius.pill),
                ),
                child: Text(actionLabel,
                    style: CvText.label.copyWith(fontSize: 12.5, color: CvColors.primaryDark)),
              ),
              const SizedBox(height: 6),
              Text(
                'CRMVoice ha interpretado tu solicitud. Revisa los datos: no se guardará nada hasta que confirmes.',
                style: CvText.body.copyWith(fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Estado global de la revisión: listo para guardar o necesita revisión.
class ReviewStatusPanel extends StatelessWidget {
  final bool ready;
  final String title;
  final String message;
  final List<String> points;

  const ReviewStatusPanel({
    super.key,
    required this.ready,
    required this.title,
    required this.message,
    this.points = const [],
  });

  @override
  Widget build(BuildContext context) {
    final tone = ready ? CvFeedbackTone.success : CvFeedbackTone.warning;
    return Semantics(
      liveRegion: true,
      container: true,
      child: AnimatedContainer(
        duration: _motion,
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: ready ? CvColors.surface : tone.soft,
          borderRadius: BorderRadius.circular(CvRadius.control + 2),
          border: Border.all(color: ready ? CvColors.border : tone.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: tone.soft, shape: BoxShape.circle),
              child: Icon(ready ? Icons.check_rounded : Icons.priority_high_rounded, size: 17, color: tone.color),
            ),
            const SizedBox(width: CvSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(title, style: CvText.label.copyWith(fontSize: 14.5)),
                  ),
                  const SizedBox(height: 2),
                  Text(message, style: CvText.helper.copyWith(fontSize: 13.5, height: 1.45)),
                  for (final p in points)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('• $p',
                          style: TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w500, color: tone.color)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grupo de filas con divisores suaves (sin tarjetas por campo).
class ReviewGroup extends StatelessWidget {
  final List<Widget> children;

  const ReviewGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, thickness: 1, color: CvColors.border),
          children[i],
        ],
      ],
    );
  }
}

/// Aviso de un campo: bloqueante (danger) o informativo (más suave).
class ReviewIssueText extends StatelessWidget {
  final String message;
  final bool blocking;

  const ReviewIssueText({super.key, required this.message, required this.blocking});

  @override
  Widget build(BuildContext context) {
    final tone = blocking ? CvFeedbackTone.danger : CvFeedbackTone.info;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(blocking ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 15, color: tone.color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                fontWeight: blocking ? FontWeight.w600 : FontWeight.w400,
                color: blocking ? tone.color : CvColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila de un dato: etiqueta pequeña, valor legible, acción a la derecha y,
/// debajo, insignia / notas / avisos.
class ReviewRow extends StatelessWidget {
  final String label;
  final Widget value;
  final List<Widget> actions;
  final List<Widget> below;
  final bool dense;

  const ReviewRow({
    super.key,
    required this.label,
    required this.value,
    this.actions = const [],
    this.below = const [],
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 8 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: CvText.helper.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    AnimatedSwitcher(duration: _motion, child: value),
                  ],
                ),
              ),
              ...actions,
            ],
          ),
          ...below,
        ],
      ),
    );
  }
}

/// Texto de valor de una fila ('—' en gris si no hay dato).
class ReviewValue extends StatelessWidget {
  final String? text;
  final bool strong;
  final bool quoted;

  const ReviewValue(this.text, {super.key, this.strong = true, this.quoted = false});

  @override
  Widget build(BuildContext context) {
    final empty = text == null || text!.isEmpty || text == '—';
    return Text(
      empty ? '—' : text!,
      key: ValueKey(text),
      style: TextStyle(
        fontSize: 15.5,
        height: 1.35,
        fontWeight: strong && !empty ? FontWeight.w600 : FontWeight.w400,
        fontStyle: quoted ? FontStyle.italic : FontStyle.normal,
        color: empty ? CvColors.textPlaceholder : CvColors.textPrimary,
      ),
    );
  }
}

/// Acción «Editar» de una fila (texto + icono; el tooltip describe el campo).
class ReviewEditButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  const ReviewEditButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.icon = Icons.edit_outlined,
    this.label = 'Editar',
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: CvColors.primaryDark,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
        ),
      ),
    );
  }
}

/// Botón de icono de una fila (buscar, quitar...).
class ReviewIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const ReviewIconButton({super.key, required this.tooltip, required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 19),
      style: IconButton.styleFrom(
        foregroundColor: CvColors.textSecondary,
        hoverColor: CvColors.background,
        minimumSize: const Size(40, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
      ),
    );
  }
}

/// Tipo visual de una insignia de coincidencia.
enum ResolutionKind {
  confirmed(Icons.check_circle_outline_rounded),
  approximate(Icons.adjust_rounded),
  derived(Icons.link_rounded),
  created(Icons.add_circle_outline_rounded),
  ambiguous(Icons.help_outline_rounded),
  missing(Icons.error_outline_rounded);

  final IconData icon;

  const ResolutionKind(this.icon);
}

/// Insignia de coincidencia: icono + texto (nunca solo color).
class ResolutionBadge extends StatelessWidget {
  final String label;
  final ResolutionKind kind;

  const ResolutionBadge({super.key, required this.label, required this.kind});

  @override
  Widget build(BuildContext context) {
    final (Color fg, Color bg) = switch (kind) {
      ResolutionKind.confirmed => (CvFeedbackTone.success.color, CvFeedbackTone.success.soft),
      ResolutionKind.approximate || ResolutionKind.derived => (CvColors.textSecondary, CvColors.background),
      ResolutionKind.created => (CvFeedbackTone.info.color, CvFeedbackTone.info.soft),
      ResolutionKind.ambiguous => (CvFeedbackTone.warning.color, CvFeedbackTone.warning.soft),
      ResolutionKind.missing => (CvFeedbackTone.danger.color, CvFeedbackTone.danger.soft),
    };
    return AnimatedContainer(
      duration: _motion,
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(CvRadius.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kind.icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, style: TextStyle(fontSize: 12, height: 1.35, fontWeight: FontWeight.w600, color: fg)),
          ),
        ],
      ),
    );
  }
}

/// Opciones entre las que elegir (candidatos del servidor): filas amplias
/// con un círculo de selección; pulsar una la elige.
class CandidateOptions extends StatelessWidget {
  final List<String> labels;
  final ValueChanged<int>? onSelected;
  final String title;

  const CandidateOptions({super.key, required this.labels, this.onSelected, this.title = 'Posibles coincidencias'});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: CvSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: CvText.helper.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(CvRadius.control),
              border: Border.all(color: CvColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: CvColors.surface,
              child: Column(
                children: [
                  for (var i = 0; i < labels.length; i++) ...[
                    if (i > 0) const Divider(height: 1, thickness: 1, color: CvColors.border),
                    Semantics(
                      button: true,
                      label: 'Elegir ${labels[i]}',
                      excludeSemantics: true,
                      onTap: onSelected == null ? null : () => onSelected!(i),
                      child: InkWell(
                        onTap: onSelected == null ? null : () => onSelected!(i),
                        hoverColor: CvColors.primarySoft.withValues(alpha: 0.6),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 46),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: CvSpace.sm, vertical: 10),
                            child: Row(
                              children: [
                                const Icon(Icons.radio_button_unchecked_rounded, size: 18, color: CvColors.textSecondary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(labels[i],
                                      style: const TextStyle(fontSize: 14.5, color: CvColors.textPrimary)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
