// Acciones rápidas sobre una actividad (H.3), comunes a Histórico,
// Calendario y ficha de cliente: cambio de estado (PATCH) y borrado con
// confirmación. El backend decide si el cambio es válido.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/crm.dart';
import '../../services/api_service.dart';
import '../ui/cv_feedback.dart';
import 'crm_ui.dart';

/// PATCH /activities/{id}. Devuelve la actividad actualizada o null si falla
/// (el error ya se ha mostrado).
Future<CrmActivity?> changeActivityStatus(
    BuildContext context, CrmActivity activity, ActivityStatus status) async {
  final api = context.read<ApiService>();
  try {
    final updated = await api.setActivityStatus(activity.id, status);
    if (context.mounted) showSuccess(context, 'Actividad marcada como ${status.label.toLowerCase()}');
    return updated;
  } catch (e) {
    if (context.mounted) showFailure(context, userMessage(e));
    return null;
  }
}

/// Confirma y borra. true si se ha borrado.
Future<bool> deleteActivityWithConfirmation(BuildContext context, CrmActivity activity) async {
  final confirmed = await confirmDestructive(
    context,
    title: 'Eliminar actividad',
    message: '¿Seguro que quieres eliminar esta actividad? No se puede deshacer.',
  );
  if (!confirmed || !context.mounted) return false;
  try {
    await context.read<ApiService>().deleteActivity(activity.id);
    if (context.mounted) showSuccess(context, 'Actividad eliminada');
    return true;
  } catch (e) {
    if (context.mounted) showFailure(context, userMessage(e));
    return false;
  }
}

enum _MenuAction { edit, delete }

/// Icono de la acción que lleva a ese estado.
IconData _statusActionIcon(ActivityStatus status) => switch (status) {
      ActivityStatus.pending => Icons.schedule_rounded,
      ActivityStatus.completed => Icons.check_circle_outline_rounded,
      ActivityStatus.cancelled => Icons.block_rounded,
    };

/// Menú "⋮" de una actividad: editar, cambios de estado permitidos y borrar
/// (I.6.3: menú contextual común CvContextMenu).
class ActivityActionsMenu extends StatelessWidget {
  final CrmActivity activity;
  final VoidCallback onEdit;
  final VoidCallback onChanged;

  const ActivityActionsMenu({super.key, required this.activity, required this.onEdit, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return CvContextMenu<Object>(
      onSelected: (value) async {
        if (value == _MenuAction.edit) {
          onEdit();
        } else if (value == _MenuAction.delete) {
          if (await deleteActivityWithConfirmation(context, activity)) onChanged();
        } else if (value is ActivityStatus) {
          if (await changeActivityStatus(context, activity, value) != null) onChanged();
        }
      },
      entries: [
        const CvMenuEntry(value: _MenuAction.edit, label: 'Editar', icon: Icons.edit_outlined),
        for (final status in activity.allowedTransitions)
          CvMenuEntry(value: status, label: statusActionLabel(status), icon: _statusActionIcon(status)),
        const CvMenuEntry(
          value: _MenuAction.delete,
          label: 'Eliminar actividad',
          icon: Icons.delete_outline_rounded,
          danger: true,
          dividerBefore: true,
        ),
      ],
    );
  }
}
