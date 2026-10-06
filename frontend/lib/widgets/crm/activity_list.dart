// Piezas del listado de Actividades (I.4.1): fila compacta de actividad,
// selector de estado y chip de filtro activo. La fila muestra los productos
// asociados como metadato discreto; el comentario no se lista (se ve al
// editar).
import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../../models/crm.dart';
import 'activity_actions.dart';
import 'crm_ui.dart';

/// Fila de actividad: acento del tipo, título y estado, fecha/hora,
/// cliente · contacto y, si los hay, productos asociados. Tocarla abre la edición; «⋮» agrupa el resto de
/// acciones (editar, cambiar estado, eliminar).
class ActivityListRow extends StatelessWidget {
  final CrmActivity activity;
  final VoidCallback onEdit;
  final VoidCallback onChanged;

  /// Por debajo de este ancho de fila el estado pasa bajo el título.
  static const double stackedBelow = 520;

  const ActivityListRow({super.key, required this.activity, required this.onEdit, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final cancelled = a.status == ActivityStatus.cancelled;
    final badge = StatusBadge(status: a.status, overdue: a.isOverdue);
    final client = a.clientName ?? '';
    final contact = a.contactName ?? '';
    final products = [...a.products.map((p) => p.name), ...a.unlinkedProducts];

    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < stackedBelow;
        return InkWell(
          onTap: onEdit,
          hoverColor: CvColors.background,
          highlightColor: CvColors.primarySoft.withValues(alpha: 0.6),
          splashColor: CvColors.primary.withValues(alpha: 0.10),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(CvSpace.md, CvSpace.sm, 48, CvSpace.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // Acento del tipo de actividad (sutil: un punto)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: getActivityColor(a.activityType ?? ''),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: CvSpace.sm),
                        Expanded(
                          child: Text(
                            a.activityType ?? 'Actividad',
                            maxLines: stacked ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: CvText.label.copyWith(
                              fontSize: 14.5,
                              color: cancelled ? CvColors.textSecondary : CvColors.textPrimary,
                              decoration: cancelled ? TextDecoration.lineThrough : null,
                              decorationColor: CvColors.textSecondary,
                            ),
                          ),
                        ),
                        if (!stacked) ...[const SizedBox(width: CvSpace.sm), badge],
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (stacked) ...[const SizedBox(height: CvSpace.xxs + 2), badge],
                          const SizedBox(height: CvSpace.xxs),
                          Text(
                            formatShortDateTime(a.datetime),
                            style: CvText.helper.copyWith(fontSize: 13),
                          ),
                          if (client.isNotEmpty || contact.isNotEmpty) ...[
                            const SizedBox(height: 1),
                            Text.rich(
                              TextSpan(children: [
                                if (client.isNotEmpty)
                                  TextSpan(
                                    text: client,
                                    style: CvText.helper.copyWith(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: CvColors.textPrimary,
                                    ),
                                  ),
                                if (client.isNotEmpty && contact.isNotEmpty) const TextSpan(text: ' · '),
                                if (contact.isNotEmpty) TextSpan(text: contact),
                              ]),
                              maxLines: stacked ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: CvText.helper.copyWith(fontSize: 13),
                            ),
                          ],
                          if (products.isNotEmpty) ...[
                            const SizedBox(height: CvSpace.xs - 2),
                            Wrap(
                              key: const Key('activity-products'),
                              spacing: CvSpace.xxs + 2,
                              runSpacing: CvSpace.xxs,
                              children: [
                                for (final name in products)
                                  // Un nombre largo se recorta, nunca desborda la fila
                                  _ProductTag(name: name, maxWidth: constraints.maxWidth - 68),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: ActivityActionsMenu(activity: a, onEdit: onEdit, onChanged: onChanged),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Producto asociado: etiqueta pequeña y neutra (metadato secundario).
class _ProductTag extends StatelessWidget {
  final String name;
  final double maxWidth;

  const _ProductTag({required this.name, required this.maxWidth});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: CvColors.background,
        borderRadius: BorderRadius.circular(CvRadius.xs + 2),
        border: Border.all(color: CvColors.border),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: CvText.helper.copyWith(fontSize: 12, height: 1.35, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// Selector compacto de estado (Todas / Pendientes / Completadas /
/// Canceladas): una sola pieza segmentada, el seleccionado resaltado.
/// Con [expand] (móvil) ocupa todo el ancho y reparte el espacio según la
/// longitud de cada etiqueta, para que las cuatro se vean completas.
class ActivityStatusFilter extends StatelessWidget {
  final ActivityStatus? selected;
  final ValueChanged<ActivityStatus?> onSelected;
  final bool expand;

  const ActivityStatusFilter({super.key, required this.selected, required this.onSelected, this.expand = false});

  static const _options = <ActivityStatus?>[null, ...ActivityStatus.values];

  static String labelFor(ActivityStatus? status) => status == null ? 'Todas' : '${status.label}s';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(CvRadius.control + 2),
        border: Border.all(color: CvColors.border),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (final status in _options)
            expand
                ? Expanded(flex: labelFor(status).length + 3, child: _segment(status, selected == status))
                : _segment(status, selected == status),
        ],
      ),
    );
  }

  Widget _segment(ActivityStatus? status, bool isSelected) {
    return Semantics(
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? CvColors.primarySoft : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CvRadius.sm + 1),
          side: BorderSide(color: isSelected ? CvColors.primary.withValues(alpha: 0.35) : Colors.transparent),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onSelected(status),
          hoverColor: CvColors.background,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: expand ? CvSpace.xxs : CvSpace.sm + 2),
              child: Center(
                widthFactor: 1,
                // En móvil, salvaguarda: si no cupiera se reduce, nunca se corta
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    labelFor(status),
                    maxLines: 1,
                    style: CvText.label.copyWith(
                      fontSize: expand ? 13 : 13.5,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected ? CvColors.primaryDark : CvColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Filtro activo: pastilla suave con su valor y «×» para quitarlo.
class ActiveFilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;

  const ActiveFilterChip({super.key, required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: CvSpace.sm, right: 2),
      decoration: BoxDecoration(
        color: CvColors.primarySoft,
        borderRadius: BorderRadius.circular(CvRadius.pill),
        border: Border.all(color: CvColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CvText.label.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: CvColors.primaryDark),
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: 'Quitar filtro',
            child: InkResponse(
              onTap: onRemove,
              radius: 16,
              child: const SizedBox.square(
                dimension: 28,
                child: Icon(Icons.close_rounded, size: 15, color: CvColors.primaryDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
