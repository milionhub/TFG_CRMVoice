// Identidad CRMVoice: símbolo de onda + wordmark.
//
// Dibujado en vector (CustomPainter) para que escale sin pérdida y funcione
// desde 16 px (favicon, avatar) hasta el tamaño de la pantalla de acceso.
// La onda conserva el concepto del logo original (señal de voz) con una
// envolvente que la atenúa en los extremos, como una señal hablada.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';

/// Onda con envolvente sinusoidal dentro de [rect], centrada en vertical.
/// [cycles] periodos completos; [phase] desplaza la onda (radianes).
Path crmVoiceWavePath(Rect rect, {double cycles = 2, double phase = 0}) {
  final path = Path();
  const steps = 96;
  final amplitude = rect.height / 2;
  for (var i = 0; i <= steps; i++) {
    final t = i / steps;
    final envelope = math.sin(math.pi * t);
    final x = rect.left + rect.width * t;
    final y = rect.center.dy -
        amplitude * envelope * math.sin(2 * math.pi * cycles * t + phase);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path;
}

/// Símbolo CRMVoice: onda blanca sobre un cuadrado redondeado del color de
/// marca. Con [plain] se dibuja solo la onda (sin fondo) en [color].
class CrmVoiceMark extends StatelessWidget {
  final double size;
  final bool plain;
  final Color? color;

  const CrmVoiceMark({super.key, this.size = 32, this.plain = false, this.color});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'CRMVoice',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _MarkPainter(plain: plain, color: color),
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  final bool plain;
  final Color? color;

  _MarkPainter({required this.plain, this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;

    if (!plain) {
      final tile = RRect.fromRectAndRadius(
        Offset.zero & Size.square(s),
        Radius.circular(s * 0.28),
      );
      canvas.drawRRect(tile, Paint()..color = color ?? CvColors.primary);
    }

    final inset = plain ? s * 0.06 : s * 0.2;
    final waveRect = Rect.fromLTRB(inset, s * 0.3, s - inset, s * 0.7);
    canvas.drawPath(
      crmVoiceWavePath(waveRect, cycles: 2),
      Paint()
        ..color = plain ? (color ?? CvColors.primary) : Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, s * (plain ? 0.1 : 0.085))
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.plain != plain || old.color != color;
}

/// Wordmark: [símbolo] CRMVoice. [markSize] fija la escala del conjunto.
class CrmVoiceWordmark extends StatelessWidget {
  final double markSize;

  const CrmVoiceWordmark({super.key, this.markSize = 32});

  @override
  Widget build(BuildContext context) {
    final fontSize = markSize * 0.66;
    return Semantics(
      label: 'CRMVoice',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CrmVoiceMark(size: markSize),
          SizedBox(width: markSize * 0.34),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'CRM'),
                TextSpan(
                  text: 'Voice',
                  style: TextStyle(
                    color: CvColors.primaryDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            style: CvText.brand.copyWith(
              fontSize: fontSize,
              letterSpacing: -fontSize * 0.02,
            ),
          ),
        ],
      ),
    );
  }
}
