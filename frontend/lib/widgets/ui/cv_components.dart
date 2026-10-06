// Componentes compartidos del interior de CRMVoice (I.2): estructura de
// página, cabecera de sección y métrica. Base para las pantallas que se
// rediseñen en I.3–I.5.
import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';

/// Cuerpo de página con scroll: margen lateral según el ancho y contenido
/// centrado con ancho máximo (no se estira en monitores grandes).
class CvPageBody extends StatelessWidget {
  final List<Widget> children;

  const CvPageBody({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final padding = CvLayout.pagePadding(width);
        final top = width < CvBreakpoints.tablet ? CvSpace.xl : 40.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(padding, top, padding, CvSpace.xxxl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: CvLayout.contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Título de sección con acción opcional a la derecha.
class CvSectionHeading extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const CvSectionHeading({super.key, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: CvText.heading.copyWith(fontSize: 17, letterSpacing: -0.2),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Tono semántico de una métrica: color de acento y fondo suave del icono.
enum CvTone {
  neutral(CvColors.primaryDark, CvColors.primarySoft),
  warning(CvColors.warning, CvColors.warningSoft),
  danger(CvColors.danger, CvColors.dangerSoft),
  success(CvColors.success, CvColors.successSoft),
  muted(CvColors.textSecondary, CvColors.background);

  final Color color;
  final Color soft;

  const CvTone(this.color, this.soft);
}

/// Métrica: icono con fondo suave del tono, cifra grande y etiqueta. El
/// color es solo acento (icono y una línea superior), la superficie es blanca.
class CvMetricTile extends StatelessWidget {
  final IconData icon;
  final CvTone tone;
  final String value;
  final String label;

  /// Resalta también la cifra con el color del tono (p. ej. vencidas > 0).
  final bool emphasize;

  const CvMetricTile({
    super.key,
    required this.icon,
    required this.tone,
    required this.value,
    required this.label,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          color: CvColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: CvColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(height: 2, color: tone.color.withValues(alpha: 0.55)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // La cifra va primero en el árbol (los tests la leen así)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              value,
                              maxLines: 1,
                              style: CvText.heading.copyWith(
                                fontSize: 26,
                                height: 1.1,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.6,
                                color: emphasize ? tone.color : CvColors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: CvSpace.xs),
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: tone.soft,
                          borderRadius: BorderRadius.circular(CvRadius.sm),
                        ),
                        child: Icon(icon, size: 18, color: tone.color),
                      ),
                    ],
                  ),
                  const SizedBox(height: CvSpace.xs),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CvText.helper.copyWith(fontSize: 13),
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
