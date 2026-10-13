import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../widgets/home/dashboard_panel.dart';
import '../widgets/recorder_card.dart';
import '../widgets/ui/cv_components.dart';

/// Saludo según la hora local (determinista para una hora dada).
String greetingFor(DateTime now) {
  final h = now.hour;
  if (h >= 6 && h < 14) return 'Buenos días';
  if (h >= 14 && h < 21) return 'Buenas tardes';
  return 'Buenas noches';
}

/// Inicio (I.2). Jerarquía: saludo → voz (protagonista) → resumen →
/// próximas actividades (las dos últimas las pinta DashboardPanel).
class HomeContent extends StatefulWidget {
  const HomeContent({super.key});

  @override
  State<HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<HomeContent> {
  bool isConnected = false;
  bool isChecking = true;

  @override
  void initState() {
    super.initState();
    _checkBackend();
  }

  Future<void> _checkBackend() async {
    try {
      final api = context.read<ApiService>();
      final message = await api.ping();
      if (!mounted) return;

      setState(() {
        isConnected = message == "ok" || message.isNotEmpty;
        isChecking = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        isConnected = false;
        isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < CvBreakpoints.tablet;

    return CvPageBody(
      children: [
        if (!isChecking && !isConnected) ...[
          StatusCard(isConnected: isConnected, isChecking: isChecking),
          const SizedBox(height: CvSpace.lg),
        ],
        const _Greeting(),
        SizedBox(height: mobile ? CvSpace.lg : CvSpace.xl + 4),
        const RecorderCard(),
        SizedBox(height: mobile ? CvSpace.xxl : 40),
        const DashboardPanel(),
      ],
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context) {
    final name = (context.watch<AuthProvider>().userName ?? '').trim();
    final firstName = name.isEmpty ? '' : name.split(RegExp(r'\s+')).first;
    final greeting = greetingFor(DateTime.now());
    final mobile = MediaQuery.sizeOf(context).width < CvBreakpoints.tablet;

    return Column(
      key: const Key('home-greeting'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            firstName.isEmpty ? '$greeting 👋' : '$greeting, $firstName 👋',
            style: CvText.heading.copyWith(fontSize: mobile ? 24 : 28, letterSpacing: -0.6),
          ),
        ),
        const SizedBox(height: CvSpace.xxs + 2),
        Text("Esto es lo que ocurre hoy en tu CRM.", style: CvText.body),
      ],
    );
  }
}

/// Aviso de conexión con el backend (solo se muestra si no hay conexión).
class StatusCard extends StatelessWidget {
  final bool isConnected;
  final bool isChecking;

  const StatusCard({
    super.key,
    required this.isConnected,
    required this.isChecking,
  });

  @override
  Widget build(BuildContext context) {
    final (Color color, Color soft, IconData icon, String text) = isChecking
        ? (CvColors.warning, CvColors.warningSoft, Icons.sync, "Comprobando conexión...")
        : isConnected
            ? (CvColors.success, CvColors.successSoft, Icons.cloud_done_outlined, "Backend conectado")
            : (CvColors.danger, CvColors.dangerSoft, Icons.cloud_off_outlined, "Backend desconectado");

    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: CvSpace.md, vertical: CvSpace.sm),
        decoration: BoxDecoration(
          color: soft,
          borderRadius: BorderRadius.circular(CvRadius.control),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: CvSpace.sm - 2),
            Expanded(
              child: Text(
                text,
                style: CvText.label.copyWith(fontWeight: FontWeight.w500, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
