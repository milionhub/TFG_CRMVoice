// Componentes compartidos de Login/Register (I.1.1).
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';

/// Campo con etiqueta visible encima (no flotante), borde suave y foco claro.
class AuthTextField extends StatelessWidget {
  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final String? hint;
  final IconData? icon;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final String? Function(String?) validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const AuthTextField({
    super.key,
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.validator,
    this.hint,
    this.icon,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
  });

  static OutlineInputBorder _border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(CvRadius.control),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(child: Text(label, style: CvText.label)),
        const SizedBox(height: CvSpace.xs),
        Semantics(
          label: label,
          child: TextFormField(
            key: fieldKey,
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            autofillHints: autofillHints,
            validator: validator,
            onChanged: onChanged,
            onFieldSubmitted: onSubmitted,
            style: CvText.input,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: CvText.input.copyWith(color: CvColors.textPlaceholder),
              prefixIcon: icon == null
                  ? null
                  : Icon(icon, size: 19, color: CvColors.textSecondary),
              suffixIcon: suffix,
              isDense: true,
              filled: true,
              fillColor: CvColors.surface,
              hoverColor: CvColors.surfaceHover,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: CvSpace.sm + 2,
                vertical: 14,
              ),
              errorStyle: CvText.helper.copyWith(color: CvColors.danger),
              errorMaxLines: 2,
              enabledBorder: _border(CvColors.borderStrong),
              focusedBorder: _border(CvColors.primaryDark, 1.6),
              errorBorder: _border(CvColors.danger),
              focusedErrorBorder: _border(CvColors.danger, 1.6),
            ),
          ),
        ),
      ],
    );
  }
}

/// Botón ojo para mostrar/ocultar la contraseña.
class PasswordVisibilityToggle extends StatelessWidget {
  final bool obscured;
  final VoidCallback onPressed;

  const PasswordVisibilityToggle({
    super.key,
    required this.obscured,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: obscured ? 'Mostrar contraseña' : 'Ocultar contraseña',
      onPressed: onPressed,
      icon: Icon(
        obscured ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        size: 19,
        color: CvColors.textSecondary,
      ),
    );
  }
}

/// CTA principal. Mantiene el color de marca durante la carga.
class AuthPrimaryButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      elevation: const WidgetStatePropertyAll(0),
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CvRadius.control),
      )),
      textStyle: const WidgetStatePropertyAll(CvText.button),
      foregroundColor: const WidgetStatePropertyAll(Colors.white),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return CvColors.primaryDark.withValues(alpha: 0.82);
        }
        if (states.contains(WidgetState.pressed)) return CvColors.primaryPressed;
        if (states.contains(WidgetState.hovered)) return CvColors.primaryStrong;
        return CvColors.primaryDark;
      }),
      side: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.focused)
              ? const BorderSide(color: CvColors.textPrimary, width: 2)
              : BorderSide.none),
    );

    return ElevatedButton(
      style: style,
      onPressed: loading ? null : onPressed,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: loading
            ? const SizedBox.square(
                key: ValueKey('loading'),
                dimension: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                  semanticsLabel: 'Cargando',
                ),
              )
            : Text(label, key: const ValueKey('label')),
      ),
    );
  }
}

/// Botón secundario "Continuar con Google" (no web: usa el plugin).
class GoogleAuthButton extends StatelessWidget {
  final VoidCallback onPressed;

  const GoogleAuthButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CvRadius.control),
        )),
        foregroundColor: const WidgetStatePropertyAll(CvColors.textPrimary),
        textStyle: const WidgetStatePropertyAll(CvText.button),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.pressed)
                ? CvColors.surfaceHover
                : CvColors.surface),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return const BorderSide(color: CvColors.primaryDark, width: 1.6);
          }
          if (states.contains(WidgetState.hovered)) {
            return const BorderSide(color: CvColors.borderHover);
          }
          return const BorderSide(color: CvColors.borderStrong);
        }),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SvgPicture.asset('assets/images/google_g.svg', height: 18, width: 18),
          const SizedBox(width: CvSpace.sm),
          const Flexible(
            child: Text('Continuar con Google', overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// Separador "—— o continúa con ——".
class AuthDivider extends StatelessWidget {
  final String text;

  const AuthDivider({super.key, this.text = 'o continúa con'});

  @override
  Widget build(BuildContext context) {
    const line = Expanded(child: Divider(color: CvColors.border, height: 1));
    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CvSpace.sm),
          child: Text(text, style: CvText.helper),
        ),
        line,
      ],
    );
  }
}

/// Error de autenticación en línea (icono + texto, no solo color).
class AuthErrorBanner extends StatelessWidget {
  final String message;

  const AuthErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: CvSpace.sm,
          vertical: CvSpace.sm - 2,
        ),
        decoration: BoxDecoration(
          color: CvColors.dangerSoft,
          border: Border.all(color: CvColors.dangerBorder),
          borderRadius: BorderRadius.circular(CvRadius.control),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.error_outline, size: 18, color: CvColors.danger),
            ),
            const SizedBox(width: CvSpace.xs + 2),
            Expanded(
              child: Text(
                message,
                style: CvText.helper.copyWith(
                  fontSize: 13.5,
                  color: CvColors.danger,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Enlace de texto ("Crear cuenta", "Inicia sesión").
class AuthLinkButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const AuthLinkButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: CvSpace.xs),
        ),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CvRadius.sm),
        )),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.pressed)
                ? CvColors.primaryStrong
                : CvColors.primaryDark),
        overlayColor: WidgetStatePropertyAll(
          CvColors.primary.withValues(alpha: 0.08),
        ),
        textStyle: WidgetStateProperty.resolveWith((states) => CvText.label.copyWith(
              fontSize: 14,
              decoration: states.contains(WidgetState.hovered)
                  ? TextDecoration.underline
                  : TextDecoration.none,
            )),
      ),
      child: Text(label),
    );
  }
}
