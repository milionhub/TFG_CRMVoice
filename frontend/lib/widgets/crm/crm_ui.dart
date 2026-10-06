// Piezas comunes de la UI funcional del CRM (H.3): tema claro, estados de
// carga/vacío/error, insignia de estado, confirmaciones y avisos.
import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../models/crm.dart';

/// Tema claro de las pantallas del CRM. La app arranca con ThemeData.dark()
/// y las pantallas existentes fijan sus colores a mano; las nuevas usan este
/// tema para que textos, campos y diálogos sean legibles sobre fondo claro.
final ThemeData crmTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primary,
    surface: Colors.white,
  ),
  scaffoldBackgroundColor: AppColors.background,
  dialogTheme: const DialogThemeData(backgroundColor: Colors.white),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
  ),
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: AppColors.border),
    ),
  ),
);

class CrmTheme extends StatelessWidget {
  final Widget child;

  const CrmTheme({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Theme(data: crmTheme, child: child);
}

// =====================================================================
// Formatos de fecha
// =====================================================================

String two(int n) => n.toString().padLeft(2, '0');

String formatDate(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';

String formatTime(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

String formatDateTime(DateTime? d) => d == null ? 'Sin fecha' : '${formatDate(d)} · ${formatTime(d)}';

/// "2026-10-01" -> "01/10/2026" (o el texto tal cual si no es una fecha).
String formatIsoDate(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso);
  return d == null ? (iso ?? '-') : formatDate(d);
}

// =====================================================================
// Actividades: color por tipo e insignia de estado
// =====================================================================

Color getActivityColor(String type) {
  switch (type.toLowerCase()) {
    case "concertar reunión":
      return const Color(0xFF3B82F6); // Azul moderno
    case "enviar presupuesto":
      return const Color(0xFFEC4899); // Rosa elegante
    case "enviar oferta":
      return const Color(0xFFF97316); // Naranja moderno
    case "registrar visita comercial":
      return const Color(0xFFEAB308); // Amarillo sofisticado
    case "realizar llamada de seguimiento":
      return const Color(0xFF22C55E); // Verde limpio
    default:
      return AppColors.primary;
  }
}

Color statusColor(ActivityStatus status) => switch (status) {
      ActivityStatus.pending => const Color(0xFFB45309),
      ActivityStatus.completed => const Color(0xFF15803D),
      ActivityStatus.cancelled => const Color(0xFF64748B),
    };

IconData statusIcon(ActivityStatus status) => switch (status) {
      ActivityStatus.pending => Icons.schedule,
      ActivityStatus.completed => Icons.check_circle_outline,
      ActivityStatus.cancelled => Icons.block,
    };

/// Texto de la acción que lleva a ese estado.
String statusActionLabel(ActivityStatus status) => switch (status) {
      ActivityStatus.pending => 'Marcar pendiente',
      ActivityStatus.completed => 'Marcar completada',
      ActivityStatus.cancelled => 'Cancelar actividad',
    };

class StatusBadge extends StatelessWidget {
  final ActivityStatus? status;
  final bool overdue;

  const StatusBadge({super.key, required this.status, this.overdue = false});

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return const SizedBox.shrink();
    final color = overdue ? const Color(0xFFB91C1C) : statusColor(s);
    final text = overdue ? 'Pendiente · vencida' : s.label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon(s), size: 13, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Estados de carga, vacío y error
// =====================================================================

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
      );
}

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorView({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Color(0xFFB91C1C)),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textPrimary)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  final IconData icon;
  final String message;
  final Widget? action;

  const EmptyView({super.key, required this.icon, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Recuadro de errores del servidor dentro de un formulario.
class FormErrorBanner extends StatelessWidget {
  final String message;
  final List<String> details;
  final Widget? action;

  const FormErrorBanner({super.key, required this.message, this.details = const [], this.action});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFB91C1C);
    final extra = details.where((d) => d != message).toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message, style: const TextStyle(color: color, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          for (final d in extra)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 4),
              child: Text('• $d', style: const TextStyle(color: color, fontSize: 13)),
            ),
          if (action != null) Padding(padding: const EdgeInsets.only(left: 20, top: 4), child: action!),
        ],
      ),
    );
  }
}

/// Sección con título y acción opcional (ficha de cliente).
class SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget? action;
  final Widget child;

  const SectionCard({super.key, required this.title, required this.icon, this.action, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ),
                if (action != null) action!,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// Confirmaciones y avisos
// =====================================================================

/// Confirmación de una acción destructiva. true solo si el usuario confirma.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Eliminar',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => CrmTheme(
      child: AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C)),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
  return result == true;
}

void showSuccess(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), backgroundColor: const Color(0xFF15803D)));
}

void showFailure(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), backgroundColor: const Color(0xFFB91C1C)));
}

/// Botón principal de guardado con estado "guardando" (evita el doble envío).
class SaveButton extends StatelessWidget {
  final bool saving;
  final VoidCallback? onPressed;
  final String label;

  const SaveButton({super.key, required this.saving, required this.onPressed, this.label = 'Guardar'});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: saving ? null : onPressed,
      icon: saving
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.check),
      label: Text(saving ? 'Guardando...' : label),
    );
  }
}
