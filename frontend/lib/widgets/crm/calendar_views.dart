// Piezas del Calendario (I.4.2): navegador de semana, superficie semanal
// (escritorio), selector de días y agenda del día (móvil). Solo
// presentación: la pantalla decide la semana, el día y las acciones.
// No se muestran comentarios ni productos (se ven al abrir la actividad).
import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../../models/crm.dart';
import '../ui/cv_components.dart';
import 'crm_ui.dart';

const _dayAbbr = ['LUN', 'MAR', 'MIÉ', 'JUE', 'VIE', 'SÁB', 'DOM'];
const _dayNames = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
const _months = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

const _motion = Duration(milliseconds: 180);

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// «5 – 11 octubre 2026», «28 septiembre – 4 octubre 2026» o, entre años,
/// «29 diciembre 2025 – 4 enero 2026».
String formatWeekRange(DateTime start, DateTime end) {
  if (start.year != end.year) {
    return '${start.day} ${_months[start.month - 1]} ${start.year} – ${end.day} ${_months[end.month - 1]} ${end.year}';
  }
  if (start.month != end.month) {
    return '${start.day} ${_months[start.month - 1]} – ${end.day} ${_months[end.month - 1]} ${end.year}';
  }
  return '${start.day} – ${end.day} ${_months[end.month - 1]} ${end.year}';
}

/// «Miércoles, 7 de octubre».
String formatDayHeading(DateTime d) => '${_dayNames[d.weekday - 1]}, ${d.day} de ${_months[d.month - 1]}';

String _dayKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

// =====================================================================
// Navegación de semana
// =====================================================================

/// ‹ rango de la semana › … [Hoy]. El rango abre el selector de fecha.
class WeekNavigator extends StatelessWidget {
  final DateTime start;
  final DateTime end;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onPickDate;
  final bool compact;

  const WeekNavigator({
    super.key,
    required this.start,
    required this.end,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
    required this.onPickDate,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              _arrow(Icons.chevron_left, 'Semana anterior', onPrevious),
              Flexible(
                child: Tooltip(
                  message: 'Ir a una fecha',
                  child: InkWell(
                    onTap: onPickDate,
                    borderRadius: BorderRadius.circular(CvRadius.sm),
                    hoverColor: CvColors.primarySoft.withValues(alpha: 0.7),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: CvSpace.xs, vertical: CvSpace.xs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: AnimatedSwitcher(
                              duration: _motion,
                              child: Text(
                                formatWeekRange(start, end),
                                key: ValueKey('range-${_dayKey(start)}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CvText.heading.copyWith(
                                  fontSize: compact ? 15.5 : 17,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          const Icon(Icons.expand_more_rounded, size: 18, color: CvColors.textSecondary),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _arrow(Icons.chevron_right, 'Semana siguiente', onNext),
            ],
          ),
        ),
        const SizedBox(width: CvSpace.xs),
        CvSecondaryButton(key: const Key('calendar-today'), label: 'Hoy', onPressed: onToday),
      ],
    );
  }

  Widget _arrow(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: CvColors.textSecondary),
      style: IconButton.styleFrom(
        hoverColor: CvColors.primarySoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
      ),
    );
  }
}

// =====================================================================
// Escritorio: superficie semanal única
// =====================================================================

/// Siete columnas dentro de una sola superficie, con divisores suaves. La
/// altura la marca el día con más actividades (mínimo compacto).
class CalendarWeekGrid extends StatelessWidget {
  final List<DateTime> days;
  final List<List<CrmActivity>> activitiesByDay;
  final DateTime today;
  final ValueChanged<CrmActivity> onOpen;
  final ValueChanged<DateTime> onCreate;

  const CalendarWeekGrid({
    super.key,
    required this.days,
    required this.activitiesByDay,
    required this.today,
    required this.onOpen,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(CvSliverListSurface.radius),
        border: Border.all(color: CvColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < days.length; i++) ...[
                if (i > 0) const VerticalDivider(width: 1, thickness: 1, color: CvColors.border),
                Expanded(
                  child: _DayColumn(
                    key: Key('calendar-day-${_dayKey(days[i])}'),
                    day: days[i],
                    isToday: sameDay(days[i], today),
                    activities: activitiesByDay[i],
                    onOpen: onOpen,
                    onCreate: onCreate,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  final DateTime day;
  final bool isToday;
  final List<CrmActivity> activities;
  final ValueChanged<CrmActivity> onOpen;
  final ValueChanged<DateTime> onCreate;

  const _DayColumn({
    super.key,
    required this.day,
    required this.isToday,
    required this.activities,
    required this.onOpen,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isToday ? CvColors.primaryDark : CvColors.textSecondary;
    return Container(
      // Hoy: tinte muy tenue en toda la columna
      color: isToday ? CvColors.primarySoft.withValues(alpha: 0.55) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(CvSpace.sm, CvSpace.sm - 2, CvSpace.xxs, CvSpace.md - 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Día de la semana y «+»; debajo, el número con todo el ancho
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        label: '${formatDayHeading(day)}${isToday ? ', hoy' : ''}',
                        excludeSemantics: true,
                        child: Text(
                          _dayAbbr[day.weekday - 1],
                          maxLines: 1,
                          style: CvText.label.copyWith(fontSize: 11.5, letterSpacing: 0.6, color: accent),
                        ),
                      ),
                    ),
                    _AddButton(dense: true, onPressed: () => onCreate(day)),
                  ],
                ),
                ExcludeSemantics(
                  child: Row(
                    children: [
                      Text(
                        '${day.day}',
                        style: CvText.heading.copyWith(
                          fontSize: 22,
                          height: 1.15,
                          color: isToday ? CvColors.primaryDark : CvColors.textPrimary,
                        ),
                      ),
                      if (isToday)
                        const Flexible(
                          child: Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _TodayTag()),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: CvColors.border),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 300),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(CvSpace.xs, CvSpace.sm - 2, CvSpace.xs, CvSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < activities.length; i++) ...[
                    if (i > 0) const SizedBox(height: CvSpace.xs),
                    CalendarActivityBlock(activity: activities[i], onTap: () => onOpen(activities[i])),
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

class _TodayTag extends StatelessWidget {
  const _TodayTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(CvRadius.pill),
        border: Border.all(color: CvColors.primary.withValues(alpha: 0.45)),
      ),
      child: Text('Hoy', style: CvText.label.copyWith(fontSize: 10.5, color: CvColors.primaryDark)),
    );
  }
}

/// «+» pequeño y lineal para crear una actividad ese día.
class _AddButton extends StatelessWidget {
  final VoidCallback onPressed;

  /// Cabecera de columna (escritorio): 32 px, para puntero.
  final bool dense;

  const _AddButton({required this.onPressed, this.dense = false});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Nueva actividad este día',
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: dense ? EdgeInsets.zero : null,
      constraints: dense ? const BoxConstraints.tightFor(width: 32, height: 32) : null,
      icon: Icon(Icons.add_rounded, size: dense ? 18 : 19, color: CvColors.textSecondary),
      style: IconButton.styleFrom(
        hoverColor: CvColors.primarySoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
      ),
    );
  }
}

/// Actividad dentro de una columna: bloque pequeño (hora, tipo, cliente,
/// contacto y estado compacto). Hover suave; tocar abre la edición.
class CalendarActivityBlock extends StatefulWidget {
  final CrmActivity activity;
  final VoidCallback onTap;

  const CalendarActivityBlock({super.key, required this.activity, required this.onTap});

  @override
  State<CalendarActivityBlock> createState() => _CalendarActivityBlockState();
}

class _CalendarActivityBlockState extends State<CalendarActivityBlock> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.activity;
    final cancelled = a.status == ActivityStatus.cancelled;
    final client = a.clientName ?? '';
    final contact = a.contactName ?? '';
    final radius = BorderRadius.circular(CvRadius.sm);

    return Material(
      key: Key('calendar-activity-${a.id}'),
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        borderRadius: radius,
        hoverColor: Colors.transparent,
        splashColor: CvColors.primary.withValues(alpha: 0.10),
        highlightColor: CvColors.primarySoft.withValues(alpha: 0.6),
        child: AnimatedContainer(
          duration: _motion,
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(CvSpace.xs + 2, CvSpace.sm - 2, CvSpace.xs + 2, CvSpace.sm - 2),
          decoration: BoxDecoration(
            color: _hover ? CvColors.surfaceHover : CvColors.surface,
            borderRadius: radius,
            border: Border.all(color: _hover ? CvColors.borderHover : CvColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _TypeDot(type: a.activityType),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      a.datetime == null ? '--:--' : formatTime(a.datetime!),
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: CvText.label.copyWith(fontSize: 12, color: CvColors.textSecondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                a.activityType ?? 'Actividad',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: CvText.label.copyWith(
                  fontSize: 13,
                  color: cancelled ? CvColors.textSecondary : CvColors.textPrimary,
                  decoration: cancelled ? TextDecoration.lineThrough : null,
                  decorationColor: CvColors.textSecondary,
                ),
              ),
              if (client.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  client,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CvText.helper.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: CvColors.textPrimary),
                ),
              ],
              if (contact.isNotEmpty)
                Text(
                  contact,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CvText.helper.copyWith(fontSize: 12),
                ),
              const SizedBox(height: 8),
              StatusBadge(status: a.status, overdue: a.isOverdue, compact: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeDot extends StatelessWidget {
  final String? type;
  final double size;

  const _TypeDot({required this.type, this.size = 7});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: getActivityColor(type ?? ''), shape: BoxShape.circle),
    );
  }
}

// =====================================================================
// Móvil: selector de días + agenda del día
// =====================================================================

/// Los siete días de la semana en una fila: abreviatura, número y puntos
/// si hay actividades. Seleccionado con fondo suave; hoy, con contorno.
class MobileWeekSelector extends StatelessWidget {
  final List<DateTime> days;
  final List<int> counts;
  final int selected;
  final DateTime today;
  final ValueChanged<int> onSelected;

  const MobileWeekSelector({
    super.key,
    required this.days,
    required this.counts,
    required this.selected,
    required this.today,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(CvSpace.xxs),
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(CvSliverListSurface.radius),
        border: Border.all(color: CvColors.border),
      ),
      child: Row(
        children: [
          for (var i = 0; i < days.length; i++)
            Expanded(
              child: _DayChip(
                key: Key('calendar-chip-${_dayKey(days[i])}'),
                day: days[i],
                count: counts[i],
                isSelected: i == selected,
                isToday: sameDay(days[i], today),
                onTap: () => onSelected(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  final DateTime day;
  final int count;
  final bool isSelected;
  final bool isToday;
  final VoidCallback onTap;

  const _DayChip({
    super.key,
    required this.day,
    required this.count,
    required this.isSelected,
    required this.isToday,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final strong = isSelected || isToday;
    final countText = count == 0 ? 'sin actividades' : (count == 1 ? '1 actividad' : '$count actividades');
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${formatDayHeading(day)}${isToday ? ', hoy' : ''}, $countText',
      onTap: onTap,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: AnimatedContainer(
          duration: _motion,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: isSelected ? CvColors.primarySoft : CvColors.surface,
            borderRadius: BorderRadius.circular(CvRadius.control),
            border: Border.all(
              color: isSelected
                  ? CvColors.primary.withValues(alpha: 0.55)
                  : isToday
                      ? CvColors.primary.withValues(alpha: 0.35)
                      : Colors.transparent,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(CvRadius.control),
              child: SizedBox(
                height: 62,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _dayAbbr[day.weekday - 1],
                      maxLines: 1,
                      style: CvText.label.copyWith(
                        fontSize: 10.5,
                        letterSpacing: 0.4,
                        color: strong ? CvColors.primaryDark : CvColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${day.day}',
                      maxLines: 1,
                      style: CvText.heading.copyWith(
                        fontSize: 17,
                        height: 1.2,
                        fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
                        color: strong ? CvColors.primaryDark : CvColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Indicador de actividad: hasta tres puntos sobrios
                    SizedBox(
                      height: 5,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < (count > 3 ? 3 : count); i++)
                            Container(
                              width: 4.5,
                              height: 4.5,
                              margin: const EdgeInsets.symmetric(horizontal: 1.5),
                              decoration: BoxDecoration(
                                color: isSelected ? CvColors.primaryDark : CvColors.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
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

/// Agenda del día seleccionado: fecha, «+» y una superficie con las
/// actividades del día (o una nota vacía ligera).
class DayAgenda extends StatelessWidget {
  final DateTime day;
  final List<CrmActivity> activities;
  final ValueChanged<CrmActivity> onOpen;
  final VoidCallback onCreate;

  const DayAgenda({super.key, required this.day, required this.activities, required this.onOpen, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CvSectionHeading(
          title: formatDayHeading(day),
          trailing: _AddButton(onPressed: onCreate),
        ),
        const SizedBox(height: CvSpace.xs),
        if (activities.isEmpty)
          const CvEmptyNote(icon: Icons.event_available_outlined, text: 'No hay actividades este día.')
        else
          CvListSurface(
            children: [
              for (final a in activities) _AgendaRow(activity: a, onTap: () => onOpen(a)),
            ],
          ),
      ],
    );
  }
}

class _AgendaRow extends StatelessWidget {
  final CrmActivity activity;
  final VoidCallback onTap;

  const _AgendaRow({required this.activity, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final cancelled = a.status == ActivityStatus.cancelled;
    final who = [
      if (a.clientName != null && a.clientName!.isNotEmpty) a.clientName!,
      if (a.contactName != null && a.contactName!.isNotEmpty) a.contactName!,
    ];
    return InkWell(
      key: Key('calendar-activity-${a.id}'),
      onTap: onTap,
      hoverColor: CvColors.background,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CvSpace.md, vertical: CvSpace.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 46,
                child: Text(
                  a.datetime == null ? '--:--' : formatTime(a.datetime!),
                  style: CvText.label.copyWith(fontSize: 13.5),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, right: CvSpace.sm - 2),
                child: _TypeDot(type: a.activityType, size: 8),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.activityType ?? 'Actividad',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CvText.label.copyWith(
                        fontSize: 14.5,
                        color: cancelled ? CvColors.textSecondary : CvColors.textPrimary,
                        decoration: cancelled ? TextDecoration.lineThrough : null,
                        decorationColor: CvColors.textSecondary,
                      ),
                    ),
                    if (who.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: who.first,
                            style: const TextStyle(fontWeight: FontWeight.w500, color: CvColors.textPrimary),
                          ),
                          if (who.length > 1) TextSpan(text: ' · ${who[1]}'),
                        ]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: CvText.helper.copyWith(fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 6),
                    StatusBadge(status: a.status, overdue: a.isOverdue),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
