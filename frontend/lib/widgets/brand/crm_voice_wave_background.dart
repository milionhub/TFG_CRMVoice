// Fondo ambiental CRMVoice: ondas de voz abstractas (I.1.1).
//
// Un único CustomPainter estático (sin animación, sin assets): velos radiales
// casi imperceptibles + grupos de líneas paralelas muy finas con forma de
// señal, en tonos del primario y con opacidades distintas para dar
// profundidad. La composición se define por densidad (no se escala la de
// escritorio) y deja limpio el centro, donde va el contenido.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design/cv_tokens.dart';

enum CvWaveDensity { mobile, tablet, desktop }

class CrmVoiceWaveBackground extends StatelessWidget {
  final CvWaveDensity density;

  /// Ancho de la columna central que queda limpia de ondas (con un borde
  /// difuminado), para que no crucen el contenido. null = sin columna limpia.
  /// Solo en escritorio: en tablet y móvil las ondas ya van en bandas
  /// superior e inferior, fuera del contenido.
  final double? clearWidth;

  const CrmVoiceWaveBackground({
    super.key,
    this.density = CvWaveDensity.desktop,
    this.clearWidth,
  });

  /// Densidad según el ancho disponible (breakpoints compartidos).
  static CvWaveDensity densityFor(double width) {
    if (width < CvBreakpoints.tablet) return CvWaveDensity.mobile;
    if (width < CvBreakpoints.desktop) return CvWaveDensity.tablet;
    return CvWaveDensity.desktop;
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _WaveBackgroundPainter(density, clearWidth),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Grupo de ondas: [lines] líneas paralelas que siguen la misma señal con
/// pequeños desfases. Coordenadas en fracciones del lienzo; [amplitude] en
/// fracción del alto (o en px si [amplitudePx] != null).
class _WaveGroup {
  final double x0, x1; // extremos horizontales
  final double y0, y1; // línea base al inicio y al final (inclinación)
  final double amplitude;
  final double? amplitudePx;
  final double cycles;
  final double phase;
  final int lines;
  final double spread; // separación vertical entre líneas (fracción del alto)
  final double maxAlpha;
  final double veilAlpha; // relleno difuminado bajo el grupo (0 = sin velo)

  const _WaveGroup({
    required this.x0,
    required this.x1,
    required this.y0,
    required this.y1,
    this.amplitude = 0,
    this.amplitudePx,
    required this.cycles,
    this.phase = 0,
    required this.lines,
    required this.spread,
    required this.maxAlpha,
    this.veilAlpha = 0,
  });
}

class _WaveBackgroundPainter extends CustomPainter {
  final CvWaveDensity density;
  final double? clearWidth;

  _WaveBackgroundPainter(this.density, this.clearWidth);

  static const _clearFeather = 96.0;

  static const _desktop = [
    // Gran cinta inferior derecha (la más presente), sale del viewport
    _WaveGroup(x0: 0.30, x1: 1.12, y0: 0.88, y1: 0.60, amplitude: 0.09,
        cycles: 1.1, phase: 0.4, lines: 9, spread: 0.010, maxAlpha: 0.36, veilAlpha: 0.08),
    // Cinta superior izquierda, entra desde fuera
    _WaveGroup(x0: -0.12, x1: 0.58, y0: 0.34, y1: 0.10, amplitude: 0.07,
        cycles: 1.3, phase: 2.2, lines: 7, spread: 0.009, maxAlpha: 0.32, veilAlpha: 0.07),
    // Señal larga y fina en la parte baja izquierda
    _WaveGroup(x0: -0.10, x1: 0.62, y0: 0.95, y1: 0.86, amplitude: 0.03,
        cycles: 2.4, phase: 1.0, lines: 3, spread: 0.006, maxAlpha: 0.24),
    // Pequeña señal superior derecha (plano lejano)
    _WaveGroup(x0: 0.70, x1: 1.08, y0: 0.14, y1: 0.24, amplitude: 0.035,
        cycles: 1.7, phase: 0.2, lines: 4, spread: 0.007, maxAlpha: 0.20),
  ];

  // Tablet: márgenes laterales estrechos → bandas arriba y abajo, menos densas
  static const _tablet = [
    _WaveGroup(x0: -0.15, x1: 1.15, y0: 0.045, y1: 0.02, amplitudePx: 34,
        cycles: 1.4, phase: 2.2, lines: 6, spread: 0.006, maxAlpha: 0.28, veilAlpha: 0.05),
    _WaveGroup(x0: -0.15, x1: 1.15, y0: 0.985, y1: 0.94, amplitudePx: 42,
        cycles: 1.1, phase: 0.4, lines: 6, spread: 0.007, maxAlpha: 0.28, veilAlpha: 0.06),
  ];

  // Móvil: dos señales suaves en los bordes, lejos del formulario
  static const _mobile = [
    _WaveGroup(x0: -0.2, x1: 1.2, y0: 0.035, y1: 0.015, amplitudePx: 16,
        cycles: 1.3, phase: 2.2, lines: 4, spread: 0.006, maxAlpha: 0.22),
    _WaveGroup(x0: -0.2, x1: 1.2, y0: 0.985, y1: 0.955, amplitudePx: 20,
        cycles: 1.1, phase: 0.4, lines: 4, spread: 0.006, maxAlpha: 0.20),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = CvColors.background);

    _paintVeils(canvas, size);

    final groups = switch (density) {
      CvWaveDensity.desktop => _desktop,
      CvWaveDensity.tablet => _tablet,
      CvWaveDensity.mobile => _mobile,
    };
    final clear = density == CvWaveDensity.desktop ? clearWidth : null;
    if (clear == null) {
      for (final g in groups) {
        _paintGroup(canvas, size, g);
      }
      return;
    }

    // Ondas en una capa propia; luego se borra la columna central
    canvas.saveLayer(bounds, Paint());
    for (final g in groups) {
      _paintGroup(canvas, size, g);
    }
    final w = size.width;
    final half = clear / 2;
    double stop(double x) => (x / w).clamp(0.0, 1.0);
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstOut
        ..shader = LinearGradient(
          colors: const [
            Color(0x00000000),
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x00000000),
          ],
          stops: [
            stop(w / 2 - half - _clearFeather),
            stop(w / 2 - half),
            stop(w / 2 + half),
            stop(w / 2 + half + _clearFeather),
          ],
        ).createShader(bounds),
    );
    canvas.restore();
  }

  void _radial(Canvas canvas, Size size, Offset center, double radius, Color color) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(rect),
    );
  }

  /// Variaciones muy pequeñas del fondo: velos teal suaves y luz superior.
  void _paintVeils(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (density != CvWaveDensity.mobile) {
      _radial(canvas, size, Offset(w * 0.10, h * 0.20), w * 0.42,
          CvColors.primarySoft);
      _radial(canvas, size, Offset(w * 0.92, h * 0.86), w * 0.48,
          CvColors.primary.withValues(alpha: 0.08));
    } else {
      _radial(canvas, size, Offset(0, 0), w * 0.9, CvColors.primarySoft);
    }
    // Luz blanca difusa arriba en el centro (limpieza detrás de la marca)
    _radial(canvas, size, Offset(w / 2, -h * 0.1), math.max(w, h) * 0.6,
        Colors.white.withValues(alpha: 0.85));
  }

  Path _wave(Size size, _WaveGroup g, double offset, double ampScale, double phaseShift) {
    final w = size.width, h = size.height;
    final amp = (g.amplitudePx ?? g.amplitude * h) * ampScale;
    final path = Path();
    const steps = 120;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      // Envolvente: entra y sale suave (señal de voz), plana en el centro
      final edge = math.min(1.0, math.min(t, 1 - t) / 0.22);
      final envelope = edge * edge * (3 - 2 * edge);
      final x = w * (g.x0 + (g.x1 - g.x0) * t);
      final base = h * (g.y0 + (g.y1 - g.y0) * t + offset);
      final y = base -
          amp * (0.35 + 0.65 * envelope) *
              math.sin(2 * math.pi * g.cycles * t + g.phase + phaseShift);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    return path;
  }

  void _paintGroup(Canvas canvas, Size size, _WaveGroup g) {
    // Velo: masa muy suave y difuminada bajo la cinta
    if (g.veilAlpha > 0) {
      final top = _wave(size, g, -g.spread * g.lines * 0.5, 1, 0);
      final bottom = _wave(size, g, g.spread * g.lines * 2.5, 0.8, 0.35);
      final veil = Path()..addPath(top, Offset.zero);
      final pts = bottom.computeMetrics().first;
      // Cierra el contorno recorriendo la curva inferior en sentido inverso
      const n = 60;
      for (var i = n; i >= 0; i--) {
        final p = pts.getTangentForOffset(pts.length * i / n)!.position;
        veil.lineTo(p.dx, p.dy);
      }
      veil.close();
      canvas.drawPath(
        veil,
        Paint()
          ..color = CvColors.primary.withValues(alpha: g.veilAlpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28),
      );
    }

    // Líneas paralelas: más opacas en el centro del grupo, más tenues fuera
    for (var i = 0; i < g.lines; i++) {
      final k = g.lines == 1 ? 0.0 : i / (g.lines - 1) - 0.5; // -0.5..0.5
      final alpha = g.maxAlpha * (1 - 0.75 * (k.abs() * 2));
      canvas.drawPath(
        _wave(size, g, k * g.spread * g.lines, 1 - 0.18 * k, k * 0.5),
        Paint()
          ..color = CvColors.primary.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == g.lines ~/ 2 ? 1.3 : 1
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveBackgroundPainter old) =>
      old.density != density || old.clearWidth != clearWidth;
}
