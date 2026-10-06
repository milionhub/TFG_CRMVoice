// Métricas de Home (H.5.2) sobre GET /dashboard: pendientes, vencidas,
// próximas y ventas registradas este mes, más las próximas actividades.
// Se recarga al volver a Home (cualquier ruta o diálogo que se cierre encima,
// p. ej. tras confirmar una acción por voz o editar algo en otra pantalla).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_colors.dart';
import '../../core/money.dart';
import '../../core/navigation.dart';
import '../../models/crm.dart';
import '../../screens/client_detail_screen.dart';
import '../../services/api_service.dart';
import '../crm/crm_ui.dart';

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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Tu resumen',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Actualizar resumen',
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
            if (_loading && data != null)
              const LinearProgressIndicator(minHeight: 2),
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
              LayoutBuilder(
                builder: (context, constraints) {
                  // Dos por fila en móvil; hasta cuatro en escritorio
                  final width = constraints.maxWidth < 440
                      ? (constraints.maxWidth - 12) / 2
                      : 200.0;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _Metric(
                        key: const Key('metric-pending'),
                        icon: Icons.schedule,
                        color: const Color(0xFFB45309),
                        value: '${data.pending}',
                        label: 'Pendientes',
                      ),
                      _Metric(
                        key: const Key('metric-overdue'),
                        icon: Icons.warning_amber_rounded,
                        color: data.overdue > 0
                            ? const Color(0xFFB91C1C)
                            : AppColors.textSecondary,
                        value: '${data.overdue}',
                        label: 'Vencidas',
                      ),
                      _Metric(
                        key: const Key('metric-upcoming'),
                        icon: Icons.event_outlined,
                        color: AppColors.primary,
                        value: '${data.upcoming7d}',
                        label: 'Próximos 7 días',
                      ),
                      _Metric(
                        key: const Key('metric-sales'),
                        icon: Icons.point_of_sale_outlined,
                        color: const Color(0xFF15803D),
                        value: formatEuros(data.salesMonthCents),
                        label:
                            'Tus ventas de ${_monthLabel(data.salesMonth)}'
                            '${data.salesMonthLines > 0 ? ' (${data.salesMonthLines})' : ''}',
                      ),
                    ].map((m) => SizedBox(width: width, child: m)).toList(),
                  );
                },
              ),
              const SizedBox(height: 12),
              if (data.isEmpty)
                const Text(
                  'Aún no tienes actividades pendientes ni ventas este mes.',
                  style: TextStyle(color: AppColors.textSecondary),
                )
              else if (data.nextActivities.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Text(
                            'Próximas actividades',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        for (final a in data.nextActivities.take(3))
                          ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.circle,
                              size: 10,
                              color: getActivityColor(a.activityType ?? ''),
                            ),
                            title: Text(a.activityType ?? 'Actividad'),
                            subtitle: Text(
                              [
                                formatDateTime(a.datetime),
                                if (a.clientName != null) a.clientName!,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: a.clientId == null
                                ? null
                                : const Icon(Icons.chevron_right),
                            onTap: a.clientId == null
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ClientDetailScreen(
                                        clientId: a.clientId!,
                                      ),
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  const _Metric({
    super.key,
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
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
