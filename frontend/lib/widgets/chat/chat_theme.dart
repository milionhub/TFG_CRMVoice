// Tema propio del chat (G.5): tokens, ThemeData claro y hoja de estilos Markdown.
// I.5.1: los tokens apuntan al sistema CRMVoice (CvColors); no es otra paleta.
//
// La app usa ThemeData.dark() globalmente (deuda de la fase I) mientras las
// pantallas pintan superficies claras a mano. El chat se envuelve en este tema
// claro y define TODOS los estilos Markdown, para que nada herede colores
// oscuros (títulos, viñetas, citas, enlaces...).
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/design/cv_tokens.dart';

class ChatColors {
  static const background = CvColors.background;
  static const surface = CvColors.surface;
  static const border = CvColors.border;
  static const textPrimary = CvColors.textPrimary;
  static const textSecondary = CvColors.textSecondary;

  /// primaryDark: texto blanco sobre él 5,2:1.
  static const accent = CvColors.primaryDark;
  static const accentSoft = CvColors.primarySoft;

  static const noticeBackground = CvColors.warningSoft;
  static const noticeBorder = Color(0xFFF0DDBA);
  static const noticeText = Color(0xFF7A4E0C);

  static const codeBackground = Color(0xFFF1F4F7);

  /// Texto de error sobre blanco (contraste > 4,5:1).
  static const error = CvColors.danger;
}

class ChatLayout {
  /// Columna de lectura de la conversación (centrada en el eje de página).
  static const maxColumnWidth = 760.0;
  static const radius = 12.0;

  /// Margen lateral de la columna según el ancho disponible.
  static double gutter(double width) => width < 800 ? 12 : (width < 1200 ? 24 : 32);
}

ThemeData chatTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: ChatColors.accent).copyWith(
    primary: ChatColors.accent,
    onPrimary: Colors.white,
    surface: ChatColors.surface,
    onSurface: ChatColors.textPrimary,
    onSurfaceVariant: ChatColors.textSecondary,
    outline: ChatColors.border,
  );
  final base = ThemeData.from(colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: ChatColors.background,
    dividerColor: ChatColors.border,
    textTheme: base.textTheme.apply(bodyColor: ChatColors.textPrimary, displayColor: ChatColors.textPrimary),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: ChatColors.accent,
      selectionColor: ChatColors.accent.withValues(alpha: 0.25),
      selectionHandleColor: ChatColors.accent,
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
  );
}

/// Hoja de estilos completa para las respuestas del asistente.
MarkdownStyleSheet chatMarkdownStyle() {
  // Cifras tabulares: importes, fechas y cantidades alinean y se leen mejor
  const body = TextStyle(
    fontSize: 15,
    height: 1.6,
    color: ChatColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  const heading = TextStyle(color: ChatColors.textPrimary, fontWeight: FontWeight.w600, height: 1.35);
  const headingPadding = EdgeInsets.only(top: 10, bottom: 2);
  return MarkdownStyleSheet(
    p: body,
    pPadding: EdgeInsets.zero,
    h1: heading.copyWith(fontSize: 18),
    h1Padding: headingPadding,
    h2: heading.copyWith(fontSize: 17),
    h2Padding: headingPadding,
    h3: heading.copyWith(fontSize: 16),
    h3Padding: headingPadding,
    h4: heading.copyWith(fontSize: 15),
    h4Padding: headingPadding,
    h5: heading.copyWith(fontSize: 15),
    h5Padding: headingPadding,
    h6: heading.copyWith(fontSize: 15),
    h6Padding: headingPadding,
    strong: const TextStyle(fontWeight: FontWeight.w600, color: ChatColors.textPrimary),
    listBulletPadding: const EdgeInsets.only(right: 6),
    em: const TextStyle(fontStyle: FontStyle.italic, color: ChatColors.textPrimary),
    del: const TextStyle(decoration: TextDecoration.lineThrough, color: ChatColors.textSecondary),
    a: const TextStyle(color: ChatColors.accent, decoration: TextDecoration.underline),
    code: const TextStyle(
      fontFamily: 'monospace',
      fontSize: 13.5,
      color: ChatColors.textPrimary,
      backgroundColor: ChatColors.codeBackground,
    ),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: ChatColors.codeBackground,
      borderRadius: BorderRadius.circular(8),
    ),
    blockquote: body.copyWith(color: ChatColors.textSecondary),
    blockquotePadding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
    blockquoteDecoration: const BoxDecoration(
      border: Border(left: BorderSide(color: ChatColors.border, width: 3)),
    ),
    listBullet: body.copyWith(color: ChatColors.textSecondary),
    listIndent: 20,
    blockSpacing: 12,
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(color: ChatColors.border)),
    ),
    tableHead: const TextStyle(fontWeight: FontWeight.w600, color: ChatColors.textPrimary, fontSize: 13.5),
    tableBody: const TextStyle(
        color: ChatColors.textPrimary, fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]),
    tableBorder: TableBorder.symmetric(inside: const BorderSide(color: ChatColors.border)),
    tableHeadAlign: TextAlign.left,
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    checkbox: const TextStyle(color: ChatColors.textSecondary),
  );
}
