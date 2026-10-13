// Calendario: semana de lunes a domingo (GET /activities?date_from&date_to),
// navegación entre semanas o a una fecha, alta global o desde un día (con la
// fecha propuesta) y edición al tocar una actividad.
//
// I.4.2: cabecera de página, navegador de semana (‹ rango › · Hoy; el rango
// abre el selector de fecha) y dos presentaciones según el ancho:
// - ancho: una sola superficie semanal con siete columnas;
// - estrecho: selector de los siete días + agenda del día seleccionado.
// Sin comentarios ni productos (se ven al editar). El formulario y el
// selector de fecha mantienen su estilo hasta la fase común de diálogos.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../core/app_colors.dart';
import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import '../models/crm.dart';
import '../widgets/crm/activity_form.dart';
import '../widgets/crm/calendar_views.dart';
import '../widgets/crm/crm_ui.dart';
import '../widgets/ui/cv_components.dart';
import 'home_screen.dart';


class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Shell común (I.2): barra lateral en escritorio, cabecera + menú en móvil
    return const AppShell(
      currentIndex: 2,
      title: "Calendario",
      body: CalendarContent(),
    );
  }
}

class CalendarContent extends StatefulWidget {
  /// Por debajo de este ancho de contenido, selector de días + agenda (las
  /// siete columnas dejarían de ser legibles). Mismo corte que el shell.
  static const double agendaBelow = CvBreakpoints.shellMobile;

  const CalendarContent({super.key});

  @override
  State<CalendarContent> createState() => _CalendarContentState();
}

class _CalendarContentState extends State<CalendarContent> {
  DateTime _currentWeekStart = DateTime.now();
  List<CrmActivity> _activities = [];
  bool _isLoading = true;
  bool _hasLoaded = false;
  String? _loadError;
  int _request = 0;

  /// Día elegido en la agenda (0 = lunes de la semana mostrada).
  int _selectedIndex = DateTime.now().weekday - 1;

  /// Sentido del último cambio de semana (para la transición).
  int _direction = 0;

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
        _hasLoaded = true;
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
      _direction = -1;
      _currentWeekStart =
          _currentWeekStart.subtract(const Duration(days: 7));
    });
    _loadActivities();
  }

  void _nextWeek() {
    setState(() {
      _direction = 1;
      _currentWeekStart =
          _currentWeekStart.add(const Duration(days: 7));
    });
    _loadActivities();
  }

  /// «Hoy»: la semana actual (misma regla que al abrir) con hoy elegido.
  void _goToday() {
    final now = DateTime.now();
    final start = _getStartOfWeek(now);
    final sameWeek = start == _currentWeekStart;
    setState(() {
      _direction = start.isBefore(_currentWeekStart) ? -1 : 1;
      _currentWeekStart = start;
      _selectedIndex = now.weekday - 1;
    });
    if (!sameWeek) _loadActivities();
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
        final start = _getStartOfWeek(picked);
        _direction = start.isBefore(_currentWeekStart) ? -1 : 1;
        _currentWeekStart = start;
        _selectedIndex = picked.weekday - 1;
      });
      _loadActivities();
    }
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

  List<DateTime> get _days => List.generate(7, (index) => _currentWeekStart.add(Duration(days: index)));

  /// Actividades de un día, por hora.
  List<CrmActivity> _activitiesOn(DateTime day) => _activities.where((a) {
        final date = a.datetime;
        if (date == null) return false;

        return date.year == day.year &&
            date.month == day.month &&
            date.day == day.day;
      }).toList()
        ..sort((a, b) => a.datetime!.compareTo(b.datetime!));

  @override
  Widget build(BuildContext context) {
    return CrmTheme(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final insets = CvPageBody.insets(constraints.maxWidth);
          final agenda = constraints.maxWidth < CalendarContent.agendaBelow;
          final compact = constraints.maxWidth < CvBreakpoints.tablet;
          final days = _days;
          return RefreshIndicator(
            onRefresh: _loadActivities,
            color: CvColors.primaryDark,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: insets,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CvPageHeader(
                    title: "Calendario",
                    subtitle: "Organiza tu semana y no pierdas ningún seguimiento.",
                    action: CvPrimaryButton(
                      label: "Nueva actividad",
                      icon: Icons.add_rounded,
                      onPressed: () => _createActivity(),
                    ),
                  ),
                  const SizedBox(height: CvSpace.xl),
                  WeekNavigator(
                    start: days.first,
                    end: days.last,
                    compact: compact,
                    onPrevious: _previousWeek,
                    onNext: _nextWeek,
                    onToday: _goToday,
                    onPickDate: _openMonthPicker,
                  ),
                  // Recarga: barra fina con altura reservada (sin saltos)
                  SizedBox(
                    height: agenda ? CvSpace.sm : CvSpace.md,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _isLoading && _hasLoaded
                          ? const SizedBox(
                              width: 64,
                              child: LinearProgressIndicator(minHeight: 2, color: CvColors.primary),
                            )
                          : null,
                    ),
                  ),
                  _content(days, agenda),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _content(List<DateTime> days, bool agenda) {
    if (_isLoading && !_hasLoaded) {
      return const CvStatePanel(
        icon: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: CvColors.primaryDark),
        ),
        title: "Cargando calendario…",
      );
    }
    if (_loadError != null && !_isLoading) {
      return CvStatePanel(
        icon: const Icon(Icons.cloud_off_outlined),
        title: "No se pudo cargar el calendario.",
        message: _loadError,
        action: CvSecondaryButton(label: "Reintentar", icon: Icons.refresh_rounded, onPressed: _loadActivities),
      );
    }

    final byDay = [for (final d in days) _activitiesOn(d)];
    final today = DateTime.now();

    // Cambio de semana: fundido con un desplazamiento mínimo en su sentido
    Widget transition(Widget child, Animation<double> animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(begin: Offset(0.012 * _direction, 0), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeOut))
                .animate(animation),
            child: child,
          ),
        );

    if (!agenda) {
      final empty = !_isLoading && byDay.every((d) => d.isEmpty);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: transition,
            child: CalendarWeekGrid(
              key: ValueKey(_currentWeekStart),
              days: days,
              activitiesByDay: byDay,
              today: today,
              onOpen: _openActivity,
              onCreate: _createActivity,
            ),
          ),
          if (empty)
            Padding(
              padding: const EdgeInsets.only(top: CvSpace.sm, left: 2),
              child: Text(
                "No hay actividades esta semana.",
                key: const Key('calendar-week-empty'),
                style: CvText.helper.copyWith(fontSize: 13),
              ),
            ),
        ],
      );
    }

    final selectedDay = days[_selectedIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MobileWeekSelector(
          days: days,
          counts: [for (final d in byDay) d.length],
          selected: _selectedIndex,
          today: today,
          onSelected: (i) => setState(() => _selectedIndex = i),
        ),
        const SizedBox(height: CvSpace.lg),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topCenter,
            children: [...previous, ?current],
          ),
          child: DayAgenda(
            key: ValueKey(selectedDay),
            day: selectedDay,
            activities: byDay[_selectedIndex],
            onOpen: _openActivity,
            onCreate: () => _createActivity(selectedDay),
          ),
        ),
      ],
    );
  }
}
