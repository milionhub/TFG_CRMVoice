// Acciones rápidas sobre una actividad (H.3), comunes a Histórico,
// Calendario y ficha de cliente: cambio de estado (PATCH) y borrado con
// confirmación. El backend decide si el cambio es válido.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/crm.dart';
import '../../services/api_service.dart';
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

/// Menú "⋮" de una actividad: editar, cambios de estado permitidos y borrar.
class ActivityActionsMenu extends StatelessWidget {
  final CrmActivity activity;
  final VoidCallback onEdit;
  final VoidCallback onChanged;

  const ActivityActionsMenu({super.key, required this.activity, required this.onEdit, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      tooltip: 'Acciones',
      icon: const Icon(Icons.more_vert),
      onSelected: (value) async {
        if (value == _MenuAction.edit) {
          onEdit();
        } else if (value == _MenuAction.delete) {
          if (await deleteActivityWithConfirmation(context, activity)) onChanged();
        } else if (value is ActivityStatus) {
          if (await changeActivityStatus(context, activity, value) != null) onChanged();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _MenuAction.edit,
          child: ListTile(dense: true, leading: Icon(Icons.edit_outlined), title: Text('Editar')),
        ),
        for (final status in activity.allowedTransitions)
          PopupMenuItem(
            value: status,
            child: ListTile(
              dense: true,
              leading: Icon(statusIcon(status), color: statusColor(status)),
              title: Text(statusActionLabel(status)),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _MenuAction.delete,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline, color: Color(0xFFB91C1C)),
            title: Text('Eliminar actividad'),
          ),
        ),
      ],
    );
  }
}
