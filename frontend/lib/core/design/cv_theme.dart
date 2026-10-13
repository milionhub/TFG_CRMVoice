// Design System CRMVoice — tipografía y tema claro.
//
// Tipografía: sans-serif de la plataforma (Roboto en Android/Web, SF en iOS,
// Segoe UI en Windows). Inter encaja con la dirección visual, pero exige
// añadir ficheros de fuente o el paquete google_fonts; se deja preparado en
// [CvText.fontFamily] para incorporarla en una pasada posterior.
import 'package:flutter/material.dart';

import 'cv_tokens.dart';

class CvText {
  CvText._();

  /// null = fuente del sistema. Cambiar aquí para usar Inter.
  static const String? fontFamily = null;

  static const brand = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    color: CvColors.textPrimary,
  );

  static const heading = TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    color: CvColors.textPrimary,
  );

  static const body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: CvColors.textSecondary,
  );

  static const label = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13.5,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: CvColors.textPrimary,
  );

  static const input = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: CvColors.textPrimary,
  );

  static const button = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );

  static const helper = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12.5,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: CvColors.textSecondary,
  );
}

class CvTheme {
  CvTheme._();

  /// Tema claro CRMVoice. En I.1.1 solo lo usan Login/Register (aplicado
  /// localmente); el resto de la app mantiene su tema hasta migrarse.
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: CvColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: CvColors.primaryDark,
      onPrimary: Colors.white,
      surface: CvColors.surface,
      onSurface: CvColors.textPrimary,
      onSurfaceVariant: CvColors.textSecondary,
      outline: CvColors.borderStrong,
      outlineVariant: CvColors.border,
      error: CvColors.danger,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: CvText.fontFamily,
      scaffoldBackgroundColor: CvColors.background,
      dividerColor: CvColors.border,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: CvColors.primaryDark,
        selectionColor: CvColors.primary.withValues(alpha: 0.3),
        selectionHandleColor: CvColors.primaryDark,
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CvRadius.xs),
        ),
        side: const BorderSide(color: CvColors.borderHover, width: 1.5),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: CvColors.textPrimary,
          borderRadius: BorderRadius.circular(CvRadius.sm),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}
