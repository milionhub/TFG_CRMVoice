// Métricas de Home (H.5.2) sobre GET /dashboard: pendientes, vencidas,
// próximas y ventas registradas este mes, más las próximas actividades.
// Se recarga al volver a Home (cualquier ruta o diálogo que se cierre encima,
// p. ej. tras confirmar una acción por voz o editar algo en otra pantalla).
// I.2: secciones «Tu resumen» (métricas con acento semántico) y «Próximas
// actividades» (filas compactas).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../../core/money.dart';
import '../../core/navigation.dart';
import '../../models/crm.dart';
import '../../screens/client_detail_screen.dart';
import '../../services/api_service.dart';
import '../crm/crm_ui.dart';
import '../ui/cv_components.dart';

class DashboardPanel extends StatefulWidget {
  const DashboardPanel({super.key});

  @override
  State<DashboardPanel> createState() => _DashboardPanelState();
}

class _DashboardPanelState extends State<DashboardPanel> with RouteAware {
  DashboardData? _data;
  bool _loading = true;
  String? _error;
  int _request = 0;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && route != _route) {
      if (_route != null) crmRouteObserver.unsubscribe(this);
      _route = route;
      crmRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    crmRouteObserver.unsubscribe(this);
    super.dispose();
  }

  /// Se ha cerrado lo que había encima de Home: los datos pueden haber cambiado.
  @override
  void didPopNext() => _load();

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<ApiService>().getDashboard();
      if (!mounted || request != _request) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = userMessage(e);
        _loading = false;
      });
    }
  }

  static const _months = [
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre',
  ];

  String _monthLabel(String? month) {
    final parts = (month ?? '').split('-');
    final m = parts.length == 2 ? int.tryParse(parts[1]) : null;
    return m == null || m < 1 || m > 12 ? 'este mes' : _months[m - 1];
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return CrmTheme(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CvSectionHeading(
            title: 'Tu resumen',
            trailing: IconButton(
              tooltip: 'Actualizar resumen',
              icon: const Icon(Icons.refresh_rounded, size: 20),
              color: CvColors.textSecondary,
              onPressed: _loading ? null : _load,
            ),
          ),
          const SizedBox(height: CvSpace.sm),
          if (_loading && data != null)
            const Padding(
              padding: EdgeInsets.only(bottom: CvSpace.xs),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (data == null && _loading)
            const SizedBox(height: 96, child: LoadingView())
          else if (data == null && _error != null)
            FormErrorBanner(
              message: 'No se pudo cargar el resumen: $_error',
              action: TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            )
          else if (data != null) ...[
            if (_error != null)
              FormErrorBanner(
                message: 'No se pudo actualizar el resumen: $_error',
              ),
            _metrics(data),
            const SizedBox(height: 40),
            const CvSectionHeading(title: 'Próximas actividades'),
            const SizedBox(height: CvSpace.sm),
            if (data.isEmpty)
              const _EmptyNote('Aún no tienes actividades pendientes ni ventas este mes.')
            else if (data.nextActivities.isEmpty)
              const _EmptyNote('No tienes actividades próximas.')
            else
              _UpcomingList(activities: data.nextActivities.take(3).toList()),
          ],
        ],
      ),
    );
  }

  Widget _metrics(DashboardData data) {
    final tiles = [
      CvMetricTile(
        key: const Key('metric-pending'),
        icon: Icons.schedule_rounded,
        tone: CvTone.warning,
        value: '${data.pending}',
        label: 'Pendientes',
      ),
      CvMetricTile(
        key: const Key('metric-overdue'),
        icon: Icons.warning_amber_rounded,
        tone: data.overdue > 0 ? CvTone.danger : CvTone.muted,
        emphasize: data.overdue > 0,
        value: '${data.overdue}',
        label: 'Vencidas',
      ),
      CvMetricTile(
        key: const Key('metric-upcoming'),
        icon: Icons.event_outlined,
        tone: CvTone.neutral,
        value: '${data.upcoming7d}',
        label: 'Próximos 7 días',
      ),
      CvMetricTile(
        key: const Key('metric-sales'),
        icon: Icons.trending_up_rounded,
        tone: CvTone.success,
        value: formatEuros(data.salesMonthCents),
        label: 'Tus ventas de ${_monthLabel(data.salesMonth)}'
            '${data.salesMonthLines > 0 ? ' (${data.salesMonthLines})' : ''}',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Cuatro en fila si caben con holgura; si no, 2x2. Cada fila iguala
        // la altura de sus métricas (etiquetas de una o dos líneas).
        const gap = CvSpace.md;
        final columns = constraints.maxWidth >= 800 ? 4 : 2;
        return Column(
          children: [
            for (var r = 0; r < tiles.length; r += columns) ...[
              if (r > 0) const SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = r; i < r + columns; i++) ...[
                      if (i > r) const SizedBox(width: gap),
                      Expanded(child: tiles[i]),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _EmptyNote extends StatelessWidget {
  final String text;

  const _EmptyNote(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: CvSpace.md + 2, vertical: CvSpace.md),
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CvColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_available_outlined, size: 20, color: CvColors.textSecondary),
          const SizedBox(width: CvSpace.sm),
          Expanded(child: Text(text, style: CvText.body.copyWith(fontSize: 14))),
        ],
      ),
    );
  }
}

/// Lista compacta de próximas actividades: fecha, tipo, hora y cliente.
class _UpcomingList extends StatelessWidget {
  final List<CrmActivity> activities;

  const _UpcomingList({required this.activities});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CvColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            for (var i = 0; i < activities.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: CvColors.border),
              _UpcomingRow(activity: activities[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  final CrmActivity activity;

  const _UpcomingRow({required this.activity});

  static const _monthsShort = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final d = a.datetime;
    final typeColor = getActivityColor(a.activityType ?? '');
    final overdue = d != null && a.status == ActivityStatus.pending && d.isBefore(DateTime.now());
    final details = [
      d == null ? 'Sin fecha' : formatTime(d),
      if (a.clientName != null) a.clientName!,
      if (a.contactName != null) a.contactName!,
    ].join(' · ');

    return InkWell(
      hoverColor: CvColors.background,
      onTap: a.clientId == null
          ? null
          : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ClientDetailScreen(clientId: a.clientId!),
                ),
              ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: CvSpace.md, vertical: CvSpace.sm),
        child: Row(
          children: [
            // Fecha: día y mes
            Container(
              width: 46,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: CvColors.background,
                borderRadius: BorderRadius.circular(CvRadius.control),
                border: Border.all(color: CvColors.border),
              ),
              child: Column(
                children: [
                  Text(
                    d == null ? '–' : '${d.day}',
                    style: CvText.label.copyWith(fontSize: 16, height: 1.1),
                  ),
                  Text(
                    d == null ? '' : _monthsShort[d.month - 1],
                    style: CvText.helper.copyWith(fontSize: 11, height: 1.2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: CvSpace.md - 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: typeColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: CvSpace.xs),
                      Flexible(
                        child: Text(
                          a.activityType ?? 'Actividad',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CvText.label.copyWith(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CvText.helper.copyWith(fontSize: 13),
                  ),
                ],
              ),
            ),
            if (overdue) ...[
              const SizedBox(width: CvSpace.xs),
              StatusBadge(status: a.status, overdue: true),
            ],
            if (a.clientId != null) ...[
              const SizedBox(width: CvSpace.xs),
              const Icon(Icons.chevron_right_rounded, color: CvColors.textSecondary),
            ],
          ],
        ),
      ),
    );
  }
}
