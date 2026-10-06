import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../core/app_colors.dart';
import '../models/crm.dart';
import '../widgets/crm/activity_form.dart';
import '../widgets/crm/crm_ui.dart';
import 'home_screen.dart';


class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;

    if (isMobile) {
      return const _MobileLayoutCalendar();
    } else {
      return const _DesktopLayoutCalendar();
    }
  }
}

class _DesktopLayoutCalendar extends StatelessWidget {
  const _DesktopLayoutCalendar();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          const Sidebar(currentIndex: 2),   // reutilizamos el sidebar del home
          const Expanded(
            child: SafeArea(
              child: CalendarContent(),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileLayoutCalendar extends StatelessWidget {
  const _MobileLayoutCalendar();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: const MobileDrawer(),  // mismo drawer del home
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const Text("Calendario"),
      ),
      body: const SafeArea(
        child: CalendarContent(),
      ),
    );
  }
}

class CalendarContent extends StatefulWidget {
  const CalendarContent({super.key});

  @override
  State<CalendarContent> createState() => _CalendarContentState();
}

class _CalendarContentState extends State<CalendarContent> {
  DateTime _currentWeekStart = DateTime.now();
  List<CrmActivity> _activities = [];
  bool _isLoading = true;
  String? _loadError;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _currentWeekStart = _getStartOfWeek(DateTime.now());
    _loadActivities();
  }

  DateTime _getStartOfWeek(DateTime date) {
    final weekday = date.weekday; // 1 = lunes
    final day = DateTime(date.year, date.month, date.day);
    return day.subtract(Duration(days: weekday - 1));
  }

  Future<void> _loadActivities() async {
    final api = context.read<ApiService>();
    final request = ++_request; // al cambiar de semana rápido gana la última

    final monday = _currentWeekStart;
    final sunday = monday.add(const Duration(days: 6));

    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final data = await api.listActivities(
        dateFrom: formatApiDate(monday),
        dateTo: formatApiDate(sunday),
      );
      if (!mounted || request != _request) return;
      setState(() {
        _activities = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _loadError = userMessage(e);
        _isLoading = false;
      });
    }
  }

  void _previousWeek() {
    setState(() {
      _currentWeekStart =
          _currentWeekStart.subtract(const Duration(days: 7));
    });
    _loadActivities();
  }

  void _nextWeek() {
    setState(() {
      _currentWeekStart =
          _currentWeekStart.add(const Duration(days: 7));
    });
    _loadActivities();
  }

  void _openMonthPicker() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _currentWeekStart,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: AppColors.primary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _currentWeekStart = _getStartOfWeek(picked);
      });
      _loadActivities();
    }
  }

  String _monthName(int month) {
    const months = [
      "Enero",
      "Febrero",
      "Marzo",
      "Abril",
      "Mayo",
      "Junio",
      "Julio",
      "Agosto",
      "Septiembre",
      "Octubre",
      "Noviembre",
      "Diciembre"
    ];
    return months[month - 1];
  }

  /// Abrir una actividad = el formulario compartido (editar, estado, borrar).
  Future<void> _openActivity(CrmActivity activity) async {
    final outcome = await openActivityForm(context, activity: activity);
    if (outcome != null && mounted) _loadActivities();
  }

  Future<void> _createActivity([DateTime? day]) async {
    final outcome = await openActivityForm(context, initialDate: day);
    if (outcome != null && mounted) _loadActivities();
  }


  @override
  Widget build(BuildContext context) {
    return CrmTheme(
      child: Container(
        color: AppColors.background,
        child: Column(
          children: [

            /// HEADER PROPIO DEL CALENDARIO
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [

                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Calendario",
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        "Vista semanal organizada por hora",
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),

                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [

                      FilledButton.icon(
                        onPressed: () => _createActivity(),
                        icon: const Icon(Icons.add),
                        label: const Text("Nueva actividad"),
                      ),

                      /// SELECTOR MES
                      GestureDetector(
                        onTap: _openMonthPicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.grey.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.calendar_today,
                                size: 16,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                "${_monthName(_currentWeekStart.month)} ${_currentWeekStart.year}",
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.expand_more, size: 18),
                            ],
                          ),
                        ),
                      ),

                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.chevron_left,
                              color: AppColors.primary,
                            ),
                            tooltip: "Semana anterior",
                            onPressed: _previousWeek,
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.chevron_right,
                              color: AppColors.primary,
                            ),
                            tooltip: "Semana siguiente",
                            onPressed: _nextWeek,
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            /// CONTENIDO
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _loadError != null
                      ? ErrorView(message: _loadError!, onRetry: _loadActivities)
                      : _buildWeekView(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeekView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // En pantallas estrechas las columnas no bajan de 150 px: scroll horizontal
        final width = constraints.maxWidth < 7 * 150 + 48 ? 7 * 150 + 48.0 : constraints.maxWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.all(24),
            width: width,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(7, (index) {
                final day = _currentWeekStart.add(
                  Duration(days: index),
                );

                return Expanded(
                  child: _buildDayColumn(day),
                );
              }),
            ),
          ),
        );
      },
    );
  }


  Widget _buildDayColumn(DateTime day) {
    final dayActivities = _activities.where((a) {
      final date = a.datetime;
      if (date == null) return false;

      return date.year == day.year &&
          date.month == day.month &&
          date.day == day.day;
    }).toList()
      ..sort((a, b) => a.datetime!.compareTo(b.datetime!));

    final isToday =
        DateTime.now().year == day.year &&
        DateTime.now().month == day.month &&
        DateTime.now().day == day.day;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isToday
            ? AppColors.primary.withValues(alpha: 0.04)
            : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: isToday
            ? Border.all(
                color: AppColors.primary,
                width: 1.5,
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: isToday
                ? AppColors.primary.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.04),
            blurRadius: isToday ? 18 : 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          /// HEADER (NO SCROLLEA)
          _buildDayHeader(day, isToday),
          const SizedBox(height: 12),

          Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.grey.withValues(alpha: 0.3),
                  Colors.transparent,
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          /// ACTIVIDADES SCROLLABLES
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (dayActivities.isEmpty)
                    const Text(
                      "Sin actividades",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),

                  ...dayActivities.map(
                    (activity) => _ActivityCard(
                      activity: activity,
                      onTap: () => _openActivity(activity),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDayHeader(DateTime day, bool isToday) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ["LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM"]
                    [day.weekday - 1],
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isToday
                      ? const Color(0xFF1565C0)
                      : Colors.grey,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "${day.day}",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: isToday
                      ? const Color(0xFF1565C0)
                      : Colors.black,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline, size: 20),
          color: AppColors.primary,
          visualDensity: VisualDensity.compact,
          tooltip: "Nueva actividad este día",
          onPressed: () => _createActivity(day),
        ),
      ],
    );
  }
}

/// Tarjeta de una actividad en el calendario (abre el formulario compartido).
class _ActivityCard extends StatefulWidget {
  final CrmActivity activity;
  final VoidCallback onTap;

  const _ActivityCard({required this.activity, required this.onTap});

  @override
  State<_ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<_ActivityCard> {
  bool isHovering = false;

  @override
  Widget build(BuildContext context) {
    final activity = widget.activity;
    final date = activity.datetime;

    final time = date != null ? formatTime(date) : "--:--";

    final activityType = activity.activityType ?? "Actividad";
    final client = activity.clientName ?? "";
    final contact = activity.contactName ?? "";
    final cancelled = activity.status == ActivityStatus.cancelled;

    final color = getActivityColor(activityType);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => isHovering = true),
      onExit: (_) => setState(() => isHovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Opacity(
          opacity: cancelled ? 0.6 : 1,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isHovering
                    ? color.withValues(alpha: 0.4)
                    : Colors.transparent,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: isHovering ? 0.08 : 0.04,
                  ),
                  blurRadius: isHovering ? 18 : 10,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [

                  /// BARRA LATERAL
                  Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                      ),
                    ),
                  ),

                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [

                          /// HORA
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: color,
                            ),
                          ),

                          const SizedBox(height: 6),

                          /// TIPO ACTIVIDAD
                          Text(
                            activityType,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: AppColors.primary,
                              decoration: cancelled ? TextDecoration.lineThrough : null,
                            ),
                          ),

                          const SizedBox(height: 6),

                          /// ESTADO
                          StatusBadge(status: activity.status, overdue: activity.isOverdue),

                          const SizedBox(height: 6),

                          /// CLIENTE
                          if (client.isNotEmpty)
                            Text(
                              client,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                            ),

                          /// CONTACTO
                          if (contact.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                contact,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
