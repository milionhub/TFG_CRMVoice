// Componentes compartidos del interior de CRMVoice. I.2: estructura de
// página, cabecera de sección y métrica. I.3.1 (Clientes): cabecera de
// página, botón primario, buscador, superficie de lista, fila de entidad,
// avatar de inicial y panel de estado. I.3.2 (ficha): botón secundario,
// acción de sección, superficie de lista corta, vacío compacto y dato con
// icono. Base para las pantallas de I.3–I.5.
import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';

/// Cuerpo de página con scroll: margen lateral según el ancho y contenido
/// centrado con ancho máximo (no se estira en monitores grandes).
class CvPageBody extends StatelessWidget {
  final List<Widget> children;

  const CvPageBody({super.key, required this.children});

  /// Márgenes de página para un ancho disponible: margen lateral mínimo y,
  /// en pantallas anchas, el necesario para centrar [CvLayout.contentMaxWidth].
  /// Lo usan también las pantallas con listas perezosas (slivers) para
  /// compartir eje y proporciones con el Inicio.
  static EdgeInsets insets(double width) {
    final side = CvLayout.pagePadding(width);
    final centered = (width - CvLayout.contentMaxWidth) / 2;
    final horizontal = centered > side ? centered : side;
    final top = width < CvBreakpoints.tablet ? CvSpace.xl : 40.0;
    return EdgeInsets.fromLTRB(horizontal, top, horizontal, CvSpace.xxxl);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: insets(constraints.maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
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

// =====================================================================
// I.3.1 · Piezas de pantallas de listado
// =====================================================================

/// Cabecera de página: título, texto de apoyo y acción principal opcional.
/// En pantallas estrechas la acción comparte fila con el título y el texto
/// de apoyo pasa debajo a todo el ancho (nunca se comprimen los dos).
class CvPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;

  const CvPageHeader({super.key, required this.title, this.subtitle, this.action});

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < CvBreakpoints.tablet;
    final heading = Semantics(
      header: true,
      child: Text(
        title,
        style: CvText.heading.copyWith(fontSize: compact ? 24 : 28, letterSpacing: -0.6),
      ),
    );
    final support = subtitle == null ? null : Text(subtitle!, style: CvText.body);

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: heading),
              if (action != null) ...[const SizedBox(width: CvSpace.sm), action!],
            ],
          ),
          if (support != null) ...[const SizedBox(height: CvSpace.xxs + 2), support],
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              if (support != null) ...[const SizedBox(height: CvSpace.xxs + 2), support],
            ],
          ),
        ),
        if (action != null) ...[const SizedBox(width: CvSpace.lg), action!],
      ],
    );
  }
}

/// Botón primario compacto de CRMVoice (acciones de página: «Nuevo cliente»).
/// Mismos colores y estados que el CTA de acceso, en tamaño de interfaz.
class CvPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  const CvPrimaryButton({super.key, required this.label, this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      elevation: const WidgetStatePropertyAll(0),
      minimumSize: const WidgetStatePropertyAll(Size(0, 42)),
      padding: WidgetStatePropertyAll(EdgeInsets.only(
        left: icon == null ? CvSpace.md + 2 : CvSpace.md - 2,
        right: CvSpace.md + 2,
      )),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CvRadius.control),
      )),
      textStyle: WidgetStatePropertyAll(CvText.button.copyWith(fontSize: 14)),
      foregroundColor: const WidgetStatePropertyAll(Colors.white),
      iconColor: const WidgetStatePropertyAll(Colors.white),
      iconSize: const WidgetStatePropertyAll(19),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return CvColors.primaryDark.withValues(alpha: 0.5);
        }
        if (states.contains(WidgetState.pressed)) return CvColors.primaryPressed;
        if (states.contains(WidgetState.hovered)) return CvColors.primaryStrong;
        return CvColors.primaryDark;
      }),
      side: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused)
          ? const BorderSide(color: CvColors.textPrimary, width: 2)
          : BorderSide.none),
    );
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    return icon == null
        ? FilledButton(style: style, onPressed: onPressed, child: text)
        : FilledButton.icon(style: style, onPressed: onPressed, icon: Icon(icon), label: text);
  }
}

/// Campo de búsqueda: icono lineal, superficie blanca, borde del sistema y
/// foco en primaryDark. Con texto muestra «Limpiar búsqueda».
class CvSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;

  const CvSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
  });

  static OutlineInputBorder _border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(CvRadius.control),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        style: CvText.input,
        cursorColor: CvColors.primaryDark,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: CvText.input.copyWith(color: CvColors.textPlaceholder),
          prefixIcon: const Icon(Icons.search_rounded, size: 20, color: CvColors.textSecondary),
          suffixIcon: value.text.isEmpty || onClear == null
              ? null
              : IconButton(
                  tooltip: 'Limpiar búsqueda',
                  icon: const Icon(Icons.close_rounded, size: 18, color: CvColors.textSecondary),
                  onPressed: onClear,
                ),
          isDense: true,
          filled: true,
          fillColor: CvColors.surface,
          hoverColor: CvColors.surfaceHover,
          contentPadding: const EdgeInsets.symmetric(horizontal: CvSpace.sm, vertical: 13),
          border: _border(CvColors.borderStrong),
          enabledBorder: _border(CvColors.borderStrong),
          focusedBorder: _border(CvColors.primaryDark, 1.6),
        ),
      ),
    );
  }
}

/// Inicial de una entidad (cliente, contacto...) sobre un cuadrado suave.
/// Se distingue del avatar circular del usuario y no usa colores aleatorios.
class CvInitialAvatar extends StatelessWidget {
  final String name;
  final double size;

  /// Círculo en lugar de cuadrado suave (personas: contactos).
  final bool circle;

  const CvInitialAvatar({super.key, required this.name, this.size = 36, this.circle = false});

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CvColors.primarySoft,
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(size >= 48 ? CvRadius.card - 2 : CvRadius.control),
        ),
        child: Text(
          initial,
          style: CvText.label.copyWith(fontSize: size * 0.42, color: CvColors.primaryDark),
        ),
      ),
    );
  }
}

/// Superficie única de listado (sliver): blanca, con borde suave, y filas
/// separadas por divisores finos. Lista perezosa para carteras grandes.
class CvSliverListSurface extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const CvSliverListSurface({super.key, required this.itemCount, required this.itemBuilder});

  static const double radius = 14;

  @override
  Widget build(BuildContext context) {
    // El borde va en una capa delante: el hover de las filas no lo tapa
    return DecoratedSliver(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: CvColors.border),
      ),
      sliver: DecoratedSliver(
        decoration: BoxDecoration(
          color: CvColors.surface,
          borderRadius: BorderRadius.circular(radius),
        ),
        sliver: SliverList.separated(
          itemCount: itemCount,
          separatorBuilder: (context, i) => const Divider(
            height: 1,
            thickness: 1,
            indent: CvSpace.md,
            endIndent: CvSpace.md,
            color: CvColors.border,
          ),
          itemBuilder: (context, i) {
            // Las esquinas de la primera y la última fila siguen el radio
            final top = i == 0 ? const Radius.circular(radius) : Radius.zero;
            final bottom = i == itemCount - 1 ? const Radius.circular(radius) : Radius.zero;
            return ClipRRect(
              borderRadius: BorderRadius.vertical(top: top, bottom: bottom),
              child: itemBuilder(context, i),
            );
          },
        ),
      ),
    );
  }
}

/// Fila de entidad clicable: avatar, dato principal, línea secundaria
/// opcional y chevron. Hover muy suave (fondo y chevron más visible).
class CvEntityRow extends StatefulWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  const CvEntityRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  @override
  State<CvEntityRow> createState() => _CvEntityRowState();
}

class _CvEntityRowState extends State<CvEntityRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.subtitle;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        hoverColor: CvColors.background,
        highlightColor: CvColors.primarySoft.withValues(alpha: 0.6),
        splashColor: CvColors.primary.withValues(alpha: 0.10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: CvSpace.md, vertical: CvSpace.sm),
            child: Row(
              children: [
                widget.leading,
                const SizedBox(width: CvSpace.sm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: CvText.label.copyWith(fontSize: 14.5),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: CvText.helper.copyWith(fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: CvSpace.xs),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _hover ? 1 : 0.55,
                  child: const Icon(Icons.chevron_right_rounded, color: CvColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Panel de estado (vacío, sin resultados, error, carga) con la misma
/// superficie que el listado, para que no quede un elemento perdido.
class CvStatePanel extends StatelessWidget {
  final Widget icon;
  final String title;
  final String? message;
  final Widget? action;

  const CvStatePanel({super.key, required this.icon, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: CvSpace.xl, vertical: 40),
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(CvSliverListSurface.radius),
        border: Border.all(color: CvColors.border),
      ),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: CvColors.primarySoft, shape: BoxShape.circle),
            child: IconTheme(
              data: const IconThemeData(size: 22, color: CvColors.primaryDark),
              child: icon,
            ),
          ),
          const SizedBox(height: CvSpace.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: CvText.label.copyWith(fontSize: 15.5),
          ),
          if (message != null) ...[
            const SizedBox(height: CvSpace.xxs + 2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(message!, textAlign: TextAlign.center, style: CvText.body.copyWith(fontSize: 14)),
            ),
          ],
          if (action != null) ...[const SizedBox(height: CvSpace.lg), action!],
        ],
      ),
    );
  }
}

// =====================================================================
// I.3.2 · Piezas de fichas de detalle
// =====================================================================

/// Acción secundaria (p. ej. «Editar»): contorno suave, texto principal.
class CvSecondaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  const CvSecondaryButton({super.key, required this.label, this.icon, this.onPressed, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      foregroundColor: CvColors.textPrimary,
      backgroundColor: CvColors.surface,
      minimumSize: const Size(0, 40),
      padding: EdgeInsets.only(left: icon == null ? CvSpace.md : CvSpace.sm + 2, right: CvSpace.md),
      side: const BorderSide(color: CvColors.borderStrong),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control)),
      textStyle: CvText.button.copyWith(fontSize: 14),
      iconColor: CvColors.textSecondary,
      iconSize: 18,
    ).copyWith(
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.hovered) ? CvColors.surfaceHover : CvColors.surface),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return const BorderSide(color: CvColors.primaryDark, width: 1.6);
        }
        return BorderSide(
            color: states.contains(WidgetState.hovered) ? CvColors.borderHover : CvColors.borderStrong);
      }),
    );
    final button = icon == null
        ? OutlinedButton(style: style, onPressed: onPressed, child: Text(label))
        : OutlinedButton.icon(style: style, onPressed: onPressed, icon: Icon(icon), label: Text(label));
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Acción de sección («+ Añadir», «+ Nueva»): texto en primaryDark, sin caja.
class CvTextAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const CvTextAction({super.key, required this.label, this.icon = Icons.add_rounded, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: CvColors.primaryDark,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: CvSpace.sm),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
        textStyle: CvText.label.copyWith(fontSize: 14),
        iconSize: 18,
      ).copyWith(
        overlayColor: WidgetStatePropertyAll(CvColors.primary.withValues(alpha: 0.08)),
      ),
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

/// Superficie única para una lista corta (contactos, actividades, ventas):
/// blanca, borde suave y filas separadas por divisores finos.
class CvListSurface extends StatelessWidget {
  final List<Widget> children;

  const CvListSurface({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(CvSliverListSurface.radius),
        border: Border.all(color: CvColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                const Divider(
                    height: 1, thickness: 1, indent: CvSpace.md, endIndent: CvSpace.md, color: CvColors.border),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Estado vacío compacto de una sección (una línea, sin panel grande).
class CvEmptyNote extends StatelessWidget {
  final IconData icon;
  final String text;

  const CvEmptyNote({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: CvSpace.md, vertical: CvSpace.md - 2),
      decoration: BoxDecoration(
        color: CvColors.surface,
        borderRadius: BorderRadius.circular(CvSliverListSurface.radius),
        border: Border.all(color: CvColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: CvColors.textSecondary),
          const SizedBox(width: CvSpace.sm),
          Expanded(child: Text(text, style: CvText.body.copyWith(fontSize: 14))),
        ],
      ),
    );
  }
}

/// Dato con icono lineal, etiqueta secundaria y valor legible (seleccionable).
class CvInfoItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const CvInfoItem({super.key, required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: CvColors.textSecondary),
        ),
        const SizedBox(width: CvSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: CvText.helper.copyWith(fontSize: 12.5)),
              const SizedBox(height: 1),
              SelectableText(value, style: CvText.input.copyWith(fontSize: 14.5)),
            ],
          ),
        ),
      ],
    );
  }
}
