// Identidad visual de CRMVoice IA (I.5.1): símbolo del asistente, ondas muy
// tenues del estado vacío e indicador de «analizando». Todo parte de la onda
// de marca (crmVoiceWavePath): sin robots, cerebros ni destellos.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design/cv_tokens.dart';
import '../brand/crm_voice_brand.dart';

/// Símbolo del asistente: la onda CRMVoice en primaryDark sobre un cuadrado
/// primarySoft. [size] 22–24 en las respuestas, ~52 en el estado vacío.
class AssistantMark extends StatelessWidget {
  final double size;

  const AssistantMark({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final large = size >= 40;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: large ? CvColors.surface : CvColors.primarySoft,
          borderRadius: BorderRadius.circular(size * (large ? 0.3 : 0.28)),
          border: Border.all(color: large ? CvColors.border : CvColors.primary.withValues(alpha: 0.25)),
          boxShadow: large
              ? const [BoxShadow(color: Color(0x0D172033), blurRadius: 18, offset: Offset(0, 6))]
              : null,
        ),
        child: CrmVoiceMark(size: size * 0.62, plain: true, color: CvColors.primaryDark),
      ),
    );
  }
}

/// Ondas de fondo del estado vacío: unas pocas líneas paralelas en teal a
/// opacidad muy baja, desvanecidas hacia los lados. Estáticas.
class ChatWaves extends StatelessWidget {
  final double height;

  const ChatWaves({super.key, this.height = 132});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: const CustomPaint(painter: _WavesPainter()),
      ),
    );
  }
}

class _WavesPainter extends CustomPainter {
  const _WavesPainter();

  static const _lines = [
    // (alto relativo, ciclos, fase, opacidad)
    (0.78, 2.0, 0.0, 0.16),
    (0.56, 2.0, 0.5, 0.11),
    (0.92, 3.0, 1.2, 0.07),
    (0.36, 3.0, 2.1, 0.08),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    for (final (h, cycles, phase, alpha) in _lines) {
      final band = Rect.fromCenter(center: rect.center, width: size.width, height: size.height * h);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(colors: [
          CvColors.primary.withValues(alpha: 0),
          CvColors.primary.withValues(alpha: alpha),
          CvColors.primary.withValues(alpha: alpha),
          CvColors.primary.withValues(alpha: 0),
        ], stops: const [0, 0.3, 0.7, 1]).createShader(rect);
      canvas.drawPath(crmVoiceWavePath(band, cycles: cycles, phase: phase), paint);
    }
  }

  @override
  bool shouldRepaint(_WavesPainter oldDelegate) => false;
}

/// Onda pequeña que se desplaza suavemente mientras el asistente responde.
/// Solo existe durante la espera; repinta un lienzo de 28×14.
class ThinkingWave extends StatefulWidget {
  const ThinkingWave({super.key});

  @override
  State<ThinkingWave> createState() => _ThinkingWaveState();
}

class _ThinkingWaveState extends State<ThinkingWave> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          width: 28,
          height: 14,
          child: CustomPaint(painter: _ThinkingPainter(_controller)),
        ),
      ),
    );
  }
}

class _ThinkingPainter extends CustomPainter {
  final Animation<double> progress;

  _ThinkingPainter(this.progress) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    // La amplitud «respira» poco: la onda nunca desaparece
    final breathe = 0.75 + 0.25 * math.sin(2 * math.pi * t);
    final band = Rect.fromCenter(
        center: size.center(Offset.zero), width: size.width, height: size.height * breathe);
    canvas.drawPath(
      crmVoiceWavePath(band, cycles: 2, phase: -2 * math.pi * t),
      Paint()
        ..color = CvColors.primaryDark
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ThinkingPainter oldDelegate) => false;
}
