// Sistema de formularios CRMVoice (I.6.2): tema de los formularios y piezas
// comunes de campo. Lo usan ActivityForm, ClientForm, ContactForm, SaleForm
// y el panel de filtros de Actividades a través de CrmFormShell.
//
// El tema [cvFormTheme] hace que TextFormField, DropdownButtonFormField,
// SegmentedButton y los selectores de fecha/hora tomen el lenguaje CRMVoice
// sin repetir estilos en cada formulario: se cambia aquí, en un solo punto.
import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../ui/cv_components.dart';
import '../ui/cv_feedback.dart';

/// Medidas comunes de los formularios.
class CvFormLayout {
  CvFormLayout._();

  /// Entre campos de una misma sección.
  static const double fieldGap = CvSpace.md;

  /// Entre secciones.
  static const double sectionGap = 28;

  /// Entre los dos campos de una fila.
  static const double pairGap = CvSpace.sm;

  /// Por debajo de este ancho, dos campos en fila se apilan.
  static const double pairMinWidth = 440;
}

OutlineInputBorder _border(Color color, [double width = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(CvRadius.control),
      borderSide: BorderSide(color: color, width: width),
    );

/// Tema claro de los formularios, construido solo con tokens Cv.
final ThemeData cvFormTheme = _buildFormTheme();

ThemeData _buildFormTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: CvColors.primaryDark).copyWith(
    primary: CvColors.primaryDark,
    onPrimary: Colors.white,
    primaryContainer: CvColors.primarySoft,
    onPrimaryContainer: CvColors.primaryDark,
    secondaryContainer: CvColors.primarySoft,
    onSecondaryContainer: CvColors.primaryDark,
    surface: CvColors.surface,
    onSurface: CvColors.textPrimary,
    onSurfaceVariant: CvColors.textSecondary,
    surfaceContainerLowest: CvColors.surface,
    surfaceContainerLow: CvColors.surface,
    surfaceContainer: CvColors.surface,
    surfaceContainerHigh: CvColors.surface,
    surfaceContainerHighest: CvColors.background,
    surfaceTint: Colors.transparent,
    outline: CvColors.borderStrong,
    outlineVariant: CvColors.border,
    error: CvColors.danger,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: CvText.fontFamily);
  const labelStyle = TextStyle(fontSize: 14.5, color: CvColors.textSecondary);
  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm));

  return base.copyWith(
    scaffoldBackgroundColor: CvColors.surface,
    canvasColor: CvColors.surface,
    dividerColor: CvColors.border,
    textTheme: base.textTheme.apply(bodyColor: CvColors.textPrimary, displayColor: CvColors.textPrimary),
    iconTheme: const IconThemeData(size: 20, color: CvColors.textSecondary),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: CvColors.primaryDark,
      selectionColor: CvColors.primary.withValues(alpha: 0.3),
      selectionHandleColor: CvColors.primaryDark,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: CvColors.primaryDark),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: CvColors.surface,
      hoverColor: CvColors.surfaceHover,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      labelStyle: labelStyle,
      floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) {
        if (states.contains(WidgetState.error)) return const TextStyle(color: CvColors.danger);
        if (states.contains(WidgetState.focused)) return const TextStyle(color: CvColors.primaryDark);
        return const TextStyle(color: CvColors.textSecondary);
      }),
      hintStyle: const TextStyle(fontSize: 14.5, color: CvColors.textPlaceholder),
      helperStyle: const TextStyle(fontSize: 12.5, color: CvColors.textSecondary),
      helperMaxLines: 2,
      errorStyle: const TextStyle(fontSize: 12.5, color: CvColors.danger),
      errorMaxLines: 3,
      prefixIconColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.focused) ? CvColors.primaryDark : CvColors.textSecondary),
      suffixIconColor: CvColors.textSecondary,
      prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      border: _border(CvColors.borderStrong),
      enabledBorder: _border(CvColors.borderStrong),
      disabledBorder: _border(CvColors.border),
      focusedBorder: _border(CvColors.primaryDark, 1.6),
      errorBorder: _border(CvColors.danger),
      focusedErrorBorder: _border(CvColors.danger, 1.6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        minimumSize: const WidgetStatePropertyAll(Size(0, 42)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: CvSpace.sm)),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control))),
        side: const WidgetStatePropertyAll(BorderSide(color: CvColors.borderStrong)),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return CvColors.primarySoft;
          if (states.contains(WidgetState.hovered)) return CvColors.surfaceHover;
          return CvColors.surface;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? CvColors.primaryDark : CvColors.textSecondary),
        overlayColor: WidgetStatePropertyAll(CvColors.primary.withValues(alpha: 0.08)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: CvColors.primaryDark,
        shape: buttonShape,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(backgroundColor: CvColors.primaryDark, shape: buttonShape),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: CvColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.card)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: CvColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: CvColors.borderStrong,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: CvColors.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: CvColors.surface,
      headerForegroundColor: CvColors.textPrimary,
      dividerColor: CvColors.border,
      rangePickerBackgroundColor: CvColors.surface,
      rangePickerHeaderBackgroundColor: CvColors.surface,
      rangePickerHeaderForegroundColor: CvColors.textPrimary,
      rangeSelectionBackgroundColor: CvColors.primarySoft,
      todayBorder: const BorderSide(color: CvColors.primary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.card)),
      cancelButtonStyle: TextButton.styleFrom(foregroundColor: CvColors.textSecondary),
      confirmButtonStyle: TextButton.styleFrom(foregroundColor: CvColors.primaryDark),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: CvColors.surface,
      dialBackgroundColor: CvColors.background,
      dialHandColor: CvColors.primaryDark,
      hourMinuteColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.selected) ? CvColors.primarySoft : CvColors.background),
      hourMinuteTextColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.selected) ? CvColors.primaryDark : CvColors.textPrimary),
      hourMinuteShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.card)),
      cancelButtonStyle: TextButton.styleFrom(foregroundColor: CvColors.textSecondary),
      confirmButtonStyle: TextButton.styleFrom(foregroundColor: CvColors.primaryDark),
    ),
  );
}

/// Chevron de los selectores (DropdownButtonFormField): los distingue de un
/// campo de texto sin cambiar de familia visual.
const Widget cvSelectChevron = Icon(Icons.keyboard_arrow_down_rounded, size: 22, color: CvColors.textSecondary);

/// Grupo de campos con un pequeño título opcional; los campos se separan
/// con [CvFormLayout.fieldGap].
class FormSection extends StatelessWidget {
  final String? title;
  final Widget? trailing;
  final List<Widget> children;

  const FormSection({super.key, this.title, this.trailing, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: EdgeInsets.only(bottom: trailing == null ? CvSpace.sm : CvSpace.xxs),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(title!, style: CvText.label.copyWith(fontSize: 13.5, letterSpacing: 0.1)),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: CvFormLayout.fieldGap),
          children[i],
        ],
      ],
    );
  }
}

/// Secciones de un formulario separadas por [CvFormLayout.sectionGap].
class FormSections extends StatelessWidget {
  final List<Widget> children;

  const FormSections({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: CvFormLayout.sectionGap),
          children[i],
        ],
      ],
    );
  }
}

/// Dos campos en fila si hay anchura; uno debajo de otro si no (nunca se
/// comprimen en móvil).
class FieldPair extends StatelessWidget {
  final Widget first;
  final Widget second;
  final double minWidth;
  final int firstFlex;
  final int secondFlex;

  const FieldPair({
    super.key,
    required this.first,
    required this.second,
    this.minWidth = CvFormLayout.pairMinWidth,
    this.firstFlex = 1,
    this.secondFlex = 1,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < minWidth
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [first, const SizedBox(height: CvFormLayout.fieldGap), second],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: firstFlex, child: first),
                const SizedBox(width: CvFormLayout.pairGap),
                Expanded(flex: secondFlex, child: second),
              ],
            ),
    );
  }
}

/// Campo que se rellena con un selector (cliente, fecha, hora...): mismo
/// aspecto que un input, con su icono a la derecha.
class TapField extends StatelessWidget {
  final String label;
  final String? value;
  final String placeholder;
  final IconData? icon;
  final IconData trailingIcon;
  final String? errorText;
  final String? helperText;
  final VoidCallback? onTap;

  const TapField({
    super.key,
    required this.label,
    required this.value,
    this.placeholder = '',
    this.icon,
    this.trailingIcon = Icons.keyboard_arrow_down_rounded,
    this.errorText,
    this.helperText,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final empty = value == null || value!.isEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(CvRadius.control),
      child: InputDecorator(
        isEmpty: false,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: icon == null ? null : Icon(icon),
          suffixIcon: Icon(trailingIcon, size: trailingIcon == Icons.keyboard_arrow_down_rounded ? 22 : 20),
          errorText: errorText,
          helperText: helperText,
          enabled: onTap != null,
        ),
        child: Text(
          empty ? placeholder : value!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, color: empty ? CvColors.textPlaceholder : CvColors.textPrimary),
        ),
      ),
    );
  }
}

/// Valor del contexto que no se cambia desde este formulario (cliente fijo,
/// grupo...): superficie neutra y legible, con un candado discreto.
class ReadOnlyField extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;

  const ReadOnlyField({super.key, required this.label, required this.value, this.icon});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value (no se cambia aquí)',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: CvColors.background,
          borderRadius: BorderRadius.circular(CvRadius.control),
          border: Border.all(color: CvColors.border),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: CvColors.textSecondary),
              const SizedBox(width: CvSpace.sm),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: const TextStyle(fontSize: 12, height: 1.3, color: CvColors.textSecondary)),
                  const SizedBox(height: 1),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, height: 1.35, fontWeight: FontWeight.w500, color: CvColors.textPrimary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: CvSpace.xs),
            const Tooltip(
              message: 'No se cambia desde aquí',
              child: Icon(Icons.lock_outline_rounded, size: 16, color: CvColors.textPlaceholder),
            ),
          ],
        ),
      ),
    );
  }
}

/// Elemento elegido (p. ej. un producto): pastilla suave con «×» para
/// quitarlo. Mismo lenguaje que los filtros activos de Actividades.
class FormTag extends StatelessWidget {
  final String label;
  final VoidCallback? onRemove;
  final String removeTooltip;

  const FormTag({super.key, required this.label, this.onRemove, this.removeTooltip = 'Quitar'});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: EdgeInsets.only(left: CvSpace.sm, right: onRemove == null ? CvSpace.sm : 2),
      decoration: BoxDecoration(
        color: CvColors.primarySoft,
        borderRadius: BorderRadius.circular(CvRadius.pill),
        border: Border.all(color: CvColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: CvColors.primaryDark),
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 2),
            Tooltip(
              message: removeTooltip,
              child: InkResponse(
                onTap: onRemove,
                radius: 16,
                child: const SizedBox.square(
                  dimension: 28,
                  child: Icon(Icons.close_rounded, size: 15, color: CvColors.primaryDark),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Acceso a «Eliminar» en el pie de un formulario: danger, discreto y
/// separado del botón principal. En pantallas estrechas, solo el icono.
class FormDeleteButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;

  const FormDeleteButton({super.key, required this.onPressed, this.label = 'Eliminar'});

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 420;
    final style = TextButton.styleFrom(
      foregroundColor: CvColors.danger,
      minimumSize: const Size(44, 42),
      padding: EdgeInsets.symmetric(horizontal: compact ? CvSpace.xs : CvSpace.sm),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
    ).copyWith(overlayColor: WidgetStatePropertyAll(CvColors.danger.withValues(alpha: 0.08)));
    if (compact) {
      return Tooltip(
        message: label,
        child: TextButton(onPressed: onPressed, style: style, child: const Icon(Icons.delete_outline_rounded, size: 20)),
      );
    }
    return TextButton.icon(
      onPressed: onPressed,
      style: style,
      icon: const Icon(Icons.delete_outline_rounded, size: 19),
      label: Text(label),
    );
  }
}

/// Error del servidor dentro de un formulario: la alerta en línea común
/// (CvInlineAlert, I.6.3) con el espaciado del formulario.
class FormErrorNotice extends StatelessWidget {
  final String message;
  final List<String> details;
  final Widget? action;

  const FormErrorNotice({super.key, required this.message, this.details = const [], this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: CvFormLayout.sectionGap - 4),
      child: CvInlineAlert(message: message, details: details, action: action),
    );
  }
}

/// Carga o error al abrir un formulario (datos previos: catálogos...).
class FormLoadState extends StatelessWidget {
  final String? error;
  final VoidCallback? onRetry;

  const FormLoadState.loading({super.key})
      : error = null,
        onRetry = null;

  const FormLoadState.error({super.key, required String this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final message = error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          if (message == null) ...[
            const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: CvSpace.md),
            Text('Cargando…', style: CvText.helper.copyWith(fontSize: 13.5)),
          ] else ...[
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(color: CvColors.dangerSoft, shape: BoxShape.circle),
              child: const Icon(Icons.cloud_off_outlined, size: 22, color: CvColors.danger),
            ),
            const SizedBox(height: CvSpace.md),
            Text(message, textAlign: TextAlign.center, style: CvText.body.copyWith(fontSize: 14.5)),
            if (onRetry != null) ...[
              const SizedBox(height: CvSpace.md),
              CvSecondaryButton(label: 'Reintentar', icon: Icons.refresh_rounded, onPressed: onRetry),
            ],
          ],
        ],
      ),
    );
  }
}
