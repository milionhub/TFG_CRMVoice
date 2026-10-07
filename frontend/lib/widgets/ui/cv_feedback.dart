// Sistema de interacciones secundarias CRMVoice (I.6.3): confirmación,
// aviso (warning/info), feedback puntual (toast), alerta en línea y menú
// contextual «⋮». Un solo lenguaje para toda la app.
//
// Regla de uso de los errores:
// - de página o sección      → CvStatePanel (cv_components.dart);
// - dentro de un formulario   → alerta en línea compacta (CvInlineAlert);
// - de una acción puntual     → toast (showCvToast).
import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import 'cv_components.dart';

/// Tono semántico de un aviso.
enum CvFeedbackTone {
  success(CvColors.success, CvColors.successSoft, Color(0xFFCDE7DA), Icons.check_circle_outline_rounded),
  warning(Color(0xFF8A5A12), CvColors.warningSoft, Color(0xFFF0DDBA), Icons.warning_amber_rounded),
  danger(CvColors.danger, CvColors.dangerSoft, CvColors.dangerBorder, Icons.error_outline_rounded),
  info(CvColors.primaryDark, CvColors.primarySoft, Color(0xFFD5E1E9), Icons.info_outline_rounded);

  /// Texto e icono (contraste ≥ 4,5:1 sobre [soft]).
  final Color color;
  final Color soft;
  final Color border;
  final IconData icon;

  const CvFeedbackTone(this.color, this.soft, this.border, this.icon);
}

const _dialogMaxWidth = 420.0;

/// Icono del tono sobre un círculo suave (diálogos).
class _ToneBadge extends StatelessWidget {
  final CvFeedbackTone tone;
  final IconData? icon;

  const _ToneBadge({required this.tone, this.icon});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: tone.soft, shape: BoxShape.circle),
        child: Icon(icon ?? tone.icon, size: 22, color: tone.color),
      ),
    );
  }
}

/// Diálogo pequeño común: icono, título, mensaje y acciones a la derecha.
class _CvDialog extends StatelessWidget {
  final CvFeedbackTone tone;
  final IconData? icon;
  final String title;
  final String message;
  final List<Widget> actions;

  const _CvDialog({required this.tone, this.icon, required this.title, required this.message, required this.actions});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          decoration: BoxDecoration(
            color: CvColors.surface,
            borderRadius: BorderRadius.circular(CvRadius.card),
            border: Border.all(color: CvColors.border),
            boxShadow: CvShadows.panel,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: Alignment.centerLeft, child: _ToneBadge(tone: tone, icon: icon)),
              const SizedBox(height: CvSpace.md),
              Semantics(
                header: true,
                child: Text(title, style: CvText.heading.copyWith(fontSize: 18, letterSpacing: -0.2)),
              ),
              const SizedBox(height: CvSpace.xs),
              Text(message, style: CvText.body.copyWith(fontSize: 14.5)),
              const SizedBox(height: CvSpace.xl),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 8,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botón destructivo (danger sólido): solo para confirmar una eliminación.
class CvDangerButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  const CvDangerButton({super.key, required this.label, this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: CvColors.danger,
      foregroundColor: Colors.white,
      minimumSize: const Size(0, 42),
      padding: const EdgeInsets.symmetric(horizontal: CvSpace.md + 2),
      textStyle: CvText.button.copyWith(fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control)),
      elevation: 0,
    ).copyWith(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) return const Color(0xFF912018);
        if (states.contains(WidgetState.hovered)) return const Color(0xFFA11F15);
        return CvColors.danger;
      }),
      side: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused)
          ? const BorderSide(color: CvColors.textPrimary, width: 2)
          : BorderSide.none),
    );
    return icon == null
        ? FilledButton(style: style, onPressed: onPressed, child: Text(label))
        : FilledButton.icon(style: style, onPressed: onPressed, icon: Icon(icon, size: 18), label: Text(label));
  }
}

/// Confirmación. true solo si el usuario confirma (Escape o fuera = no).
/// [destructive]: botón danger y tono danger en el icono.
Future<bool> showCvConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancelar',
  bool destructive = true,
  IconData? icon,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: CvColors.textPrimary.withValues(alpha: 0.32),
    builder: (dialogContext) => _CvDialog(
      tone: destructive ? CvFeedbackTone.danger : CvFeedbackTone.info,
      icon: icon ?? (destructive ? Icons.delete_outline_rounded : null),
      title: title,
      message: message,
      actions: [
        CvSecondaryButton(label: cancelLabel, onPressed: () => Navigator.pop(dialogContext, false)),
        destructive
            ? CvDangerButton(label: confirmLabel, onPressed: () => Navigator.pop(dialogContext, true))
            : CvPrimaryButton(label: confirmLabel, onPressed: () => Navigator.pop(dialogContext, true)),
      ],
    ),
  );
  return result == true;
}

/// Aviso informativo (warning o info) con una sola acción de cierre.
Future<void> showCvNotice(
  BuildContext context, {
  required String title,
  required String message,
  CvFeedbackTone tone = CvFeedbackTone.info,
  String actionLabel = 'Entendido',
}) {
  return showDialog<void>(
    context: context,
    barrierColor: CvColors.textPrimary.withValues(alpha: 0.32),
    builder: (dialogContext) => _CvDialog(
      tone: tone,
      title: title,
      message: message,
      actions: [CvPrimaryButton(label: actionLabel, onPressed: () => Navigator.pop(dialogContext))],
    ),
  );
}

// =====================================================================
// Feedback puntual (toast)
// =====================================================================

/// Toast compacto CRMVoice sobre SnackBar flotante: superficie blanca,
/// borde suave, icono del tono y texto oscuro. Sustituye al anterior.
void showCvToast(BuildContext context, String message, {CvFeedbackTone tone = CvFeedbackTone.success}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final width = MediaQuery.sizeOf(context).width;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        duration: Duration(milliseconds: tone == CvFeedbackTone.danger ? 5000 : 3200),
        width: width >= 600 ? 420 : null,
        margin: width >= 600 ? null : const EdgeInsets.fromLTRB(16, 0, 16, 16),
        content: _Toast(message: message, tone: tone),
      ),
    );
}

class _Toast extends StatelessWidget {
  final String message;
  final CvFeedbackTone tone;

  const _Toast({required this.message, required this.tone});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
        decoration: BoxDecoration(
          color: CvColors.surface,
          borderRadius: BorderRadius.circular(CvRadius.control + 2),
          border: Border.all(color: CvColors.border),
          boxShadow: const [
            BoxShadow(color: Color(0x14172033), blurRadius: 24, offset: Offset(0, 8)),
            BoxShadow(color: Color(0x0A172033), blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: tone.soft, shape: BoxShape.circle),
              child: Icon(tone.icon, size: 17, color: tone.color),
            ),
            const SizedBox(width: CvSpace.sm),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w500, color: CvColors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// Alerta en línea
// =====================================================================

/// Alerta compacta dentro de un formulario o sección: icono + texto (no
/// solo color), detalles opcionales y una acción.
class CvInlineAlert extends StatelessWidget {
  final String message;
  final List<String> details;
  final Widget? action;
  final CvFeedbackTone tone;

  const CvInlineAlert({
    super.key,
    required this.message,
    this.details = const [],
    this.action,
    this.tone = CvFeedbackTone.danger,
  });

  @override
  Widget build(BuildContext context) {
    final extra = details.where((d) => d != message).toList();
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: tone.soft,
          borderRadius: BorderRadius.circular(CvRadius.control),
          border: Border.all(color: tone.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(tone.icon, size: 19, color: tone.color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message,
                      style: TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w600, color: tone.color)),
                  for (final d in extra)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('• $d', style: TextStyle(fontSize: 13, height: 1.4, color: tone.color)),
                    ),
                  if (action != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: DefaultTextStyle.merge(style: const TextStyle(color: CvColors.textPrimary), child: action!),
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

// =====================================================================
// Menú contextual «⋮»
// =====================================================================

/// Una opción del menú. [danger] solo para acciones destructivas;
/// [dividerBefore] la separa del grupo anterior.
class CvMenuEntry<T> {
  final T value;
  final String label;
  final IconData icon;
  final Color? iconColor;
  final bool danger;
  final bool dividerBefore;

  const CvMenuEntry({
    required this.value,
    required this.label,
    required this.icon,
    this.iconColor,
    this.danger = false,
    this.dividerBefore = false,
  });
}

/// Botón «⋮» con un menú compacto: iconos lineales, filas de 42 px, hover
/// suave y la acción destructiva en danger y separada.
class CvContextMenu<T> extends StatelessWidget {
  final List<CvMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final String tooltip;

  const CvContextMenu({super.key, required this.entries, required this.onSelected, this.tooltip = 'Acciones'});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      icon: const Icon(Icons.more_vert_rounded, color: CvColors.textSecondary),
      style: IconButton.styleFrom(
        hoverColor: CvColors.background,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control)),
      ),
      color: CvColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: const Color(0x33172033),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
      menuPadding: const EdgeInsets.symmetric(vertical: CvSpace.xxs + 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CvRadius.control + 2),
        side: const BorderSide(color: CvColors.border),
      ),
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final e in entries) ...[
          if (e.dividerBefore) const PopupMenuDivider(height: 9, color: CvColors.border),
          PopupMenuItem<T>(
            value: e.value,
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: CvSpace.md - 2),
            child: Row(
              children: [
                Icon(e.icon, size: 18, color: e.danger ? CvColors.danger : (e.iconColor ?? CvColors.textSecondary)),
                const SizedBox(width: CvSpace.sm),
                Flexible(
                  child: Text(
                    e.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: e.danger ? CvColors.danger : CvColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Acción directa de una fila (p. ej. el lápiz de un contacto): mismo
/// tamaño, color y hover que el botón «⋮» del menú contextual.
class CvRowIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const CvRowIconButton({super.key, required this.tooltip, required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: CvColors.textSecondary),
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        hoverColor: CvColors.background,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control)),
      ),
    );
  }
}
