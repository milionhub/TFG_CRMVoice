// Design System CRMVoice (Fase I) — tokens base.
//
// Base creada en I.1.1 (Login/Register) y extendida en I.2 (shell + Home).
// Se irá ampliando en I.3–I.5 a medida que se rediseñen el resto de
// pantallas; mientras tanto conviven con AppColors (core/app_colors.dart),
// que siguen usando las pantallas aún no migradas.
import 'package:flutter/material.dart';

/// Paleta CRMVoice: azul verdoso desaturado sobre una base neutra fría.
///
/// Contraste (WCAG) sobre blanco:
/// - [primary] 3.0:1 → solo elementos gráficos (logo, iconos, acentos).
/// - [primaryDark] 5.2:1 → texto, enlaces y fondo de CTA con texto blanco.
/// - [textSecondary] 4.8:1 → texto secundario.
class CvColors {
  CvColors._();

  // Marca
  static const primary = Color(0xFF789AAF);
  static const primaryDark = Color(0xFF4D6F84);
  static const primaryStrong = Color(0xFF3F5E71); // hover del CTA
  static const primaryPressed = Color(0xFF34505F);
  static const primarySoft = Color(0xFFEEF3F6);

  // Neutros
  static const background = Color(0xFFF6F8FA);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceHover = Color(0xFFF8FAFB);
  static const textPrimary = Color(0xFF172033);
  static const textSecondary = Color(0xFF667085);
  static const textPlaceholder = Color(0xFF98A2B3);
  static const border = Color(0xFFE3E8EE);
  static const borderStrong = Color(0xFFD0D7E0); // bordes de inputs/botones
  static const borderHover = Color(0xFFB4BFCC);

  // Estados
  static const success = Color(0xFF2F7D5B);
  static const successSoft = Color(0xFFEDF7F2);
  static const warning = Color(0xFFB7791F);
  static const warningSoft = Color(0xFFFDF6EA);
  static const danger = Color(0xFFB42318);
  static const dangerSoft = Color(0xFFFEF3F2);
  static const dangerBorder = Color(0xFFFECDCA);
}

/// Escala de espaciado (múltiplos de 4).
class CvSpace {
  CvSpace._();

  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Radios: contenedores 14–16, controles 10, chips completos.
class CvRadius {
  CvRadius._();

  static const double xs = 4;
  static const double sm = 8;
  static const double control = 10;
  static const double card = 16;
  static const double pill = 999;
}

/// Sombras muy suaves: la jerarquía la marcan surface + borde.
class CvShadows {
  CvShadows._();

  static const panel = [
    BoxShadow(color: Color(0x0A172033), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F172033), blurRadius: 32, offset: Offset(0, 12)),
  ];
}

/// Breakpoints compartidos (ancho lógico disponible).
class CvBreakpoints {
  CvBreakpoints._();

  static const double tablet = 600;
  static const double desktop = 1024;

  /// Shell: por debajo, navegación móvil (cabecera + menú lateral). Es el
  /// mismo corte que usan las pantallas de sección desde H.5.
  static const double shellMobile = 800;

  /// Shell: por debajo, barra lateral compacta (solo iconos).
  static const double shellExpanded = 1100;
}

/// Estructura del contenido dentro del shell.
class CvLayout {
  CvLayout._();

  static const double sidebarWidth = 248;
  static const double sidebarCompactWidth = 76;

  /// Ancho máximo del contenido: no se estira en monitores grandes.
  static const double contentMaxWidth = 1080;

  /// Margen lateral del contenido según el ancho disponible.
  static double pagePadding(double width) {
    if (width < CvBreakpoints.tablet) return CvSpace.lg;
    if (width < CvBreakpoints.desktop) return CvSpace.xxl - 4;
    return 40;
  }
}
