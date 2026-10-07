// Presentación común de los formularios del CRM (H.3; rediseño I.6.2):
// diálogo centrado en escritorio y pantalla completa en móvil (o panel
// inferior, si se pide), con la acción de guardar siempre visible (fuera del
// área con scroll). Incluye el selector con búsqueda (clientes, productos...).
//
// Las piezas de campo y el tema de formulario están en form_fields.dart.
import 'package:flutter/material.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../ui/cv_components.dart';
import 'form_fields.dart';

export 'form_fields.dart';

/// Por debajo de este ancho, el formulario ocupa la pantalla completa.
const double _fullScreenBelow = 700;

enum _Mode { dialog, fullScreen, sheet }

/// Abre un formulario y devuelve lo que este pase a Navigator.pop.
///
/// [sheetOnMobile]: en móvil, panel inferior en lugar de pantalla completa
/// (formularios cortos de selección, como los filtros).
Future<T?> openCrmForm<T>(BuildContext context, Widget form, {bool sheetOnMobile = false}) {
  final narrow = MediaQuery.sizeOf(context).width < _fullScreenBelow;
  Widget themed(Widget child) => Theme(data: cvFormTheme, child: child);

  if (narrow && sheetOnMobile) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: CvColors.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _FormMode(mode: _Mode.sheet, child: themed(form)),
    );
  }
  if (narrow) {
    return Navigator.of(context).push<T>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FormMode(mode: _Mode.fullScreen, child: themed(form)),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    barrierColor: CvColors.textPrimary.withValues(alpha: 0.32),
    builder: (_) => _FormMode(mode: _Mode.dialog, child: themed(form)),
  );
}

class _FormMode extends InheritedWidget {
  final _Mode mode;

  const _FormMode({required this.mode, required super.child});

  @override
  bool updateShouldNotify(_FormMode oldWidget) => mode != oldWidget.mode;
}

/// Esqueleto de un formulario: cabecera (título + cerrar), cuerpo con scroll
/// y pie de acciones: [leading] a la izquierda (p. ej. Eliminar) y
/// [actions] a la derecha (secundaria y principal).
class CrmFormShell extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? leading;
  final double maxWidth;

  /// Guardando: no se puede cerrar (ni con la X ni con "atrás") hasta que
  /// responda el backend, para que quien abrió el formulario se entere.
  final bool busy;

  /// Si se indica, cerrar (X o "atrás") llama a esto en vez de cerrar
  /// directamente (p. ej. para confirmar que se descartan cambios).
  final VoidCallback? onClose;

  const CrmFormShell({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.leading,
    this.maxWidth = 620,
    this.busy = false,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final mode = context.dependOnInheritedWidgetOfExactType<_FormMode>()?.mode ?? _Mode.fullScreen;
    final close = busy ? null : (onClose ?? () => Navigator.maybePop(context));
    void onPopInvoked(bool didPop, Object? result) {
      if (!didPop && !busy) onClose?.call();
    }

    final hasFooter = actions.isNotEmpty || leading != null;
    final footer = !hasFooter
        ? null
        : _Footer(leading: leading, actions: actions, padding: mode == _Mode.dialog ? 24 : 16);

    return PopScope(
      canPop: !busy && onClose == null,
      onPopInvokedWithResult: onPopInvoked,
      child: switch (mode) {
        _Mode.fullScreen => _fullScreen(close, footer),
        _Mode.sheet => _sheet(context, close, footer),
        _Mode.dialog => _dialog(context, close, footer),
      },
    );
  }

  Widget _scrollBody(EdgeInsets padding) => SingleChildScrollView(padding: padding, child: body);

  Widget _fullScreen(VoidCallback? close, Widget? footer) {
    return Scaffold(
      backgroundColor: CvColors.surface,
      appBar: AppBar(
        backgroundColor: CvColors.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        titleSpacing: 0,
        shape: const Border(bottom: BorderSide(color: CvColors.border)),
        title: Text(title, style: CvText.heading.copyWith(fontSize: 17.5, letterSpacing: -0.2)),
        leading: _CloseButton(onPressed: close),
      ),
      body: SafeArea(child: _scrollBody(const EdgeInsets.fromLTRB(20, 24, 20, 28))),
      bottomNavigationBar: footer == null ? null : SafeArea(top: false, child: footer),
    );
  }

  Widget _sheet(BuildContext context, VoidCallback? close, Widget? footer) {
    final height = MediaQuery.sizeOf(context).height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: height * 0.88),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(title: title, onClose: close, padding: const EdgeInsets.fromLTRB(20, 0, 8, 12)),
          const Divider(height: 1, thickness: 1, color: CvColors.border),
          Flexible(child: _scrollBody(const EdgeInsets.fromLTRB(20, 20, 20, 24))),
          if (footer != null)
            Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: footer),
        ],
      ),
    );
  }

  Widget _dialog(BuildContext context, VoidCallback? close, Widget? footer) {
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: height * 0.9),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CvColors.surface,
            borderRadius: BorderRadius.circular(CvRadius.card),
            border: Border.all(color: CvColors.border),
            boxShadow: CvShadows.panel,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(CvRadius.card),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(title: title, onClose: close, padding: const EdgeInsets.fromLTRB(28, 20, 16, 16)),
                const Divider(height: 1, thickness: 1, color: CvColors.border),
                Flexible(child: _scrollBody(const EdgeInsets.fromLTRB(28, 24, 28, 28))),
                ?footer,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback? onClose;
  final EdgeInsets padding;

  const _Header({required this.title, required this.onClose, required this.padding});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: CvText.heading.copyWith(fontSize: 20, letterSpacing: -0.3)),
            ),
          ),
          const SizedBox(width: CvSpace.xs),
          _CloseButton(onPressed: onClose),
        ],
      ),
    );
  }
}

/// «×» de cerrar: objetivo de 44 px, discreto, hover suave.
class _CloseButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const _CloseButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Cerrar',
      onPressed: onPressed,
      icon: const Icon(Icons.close_rounded, size: 22),
      style: IconButton.styleFrom(
        foregroundColor: CvColors.textSecondary,
        hoverColor: CvColors.background,
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control)),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final Widget? leading;
  final List<Widget> actions;
  final double padding;

  const _Footer({required this.leading, required this.actions, required this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(padding - 4, 14, padding, 14),
      decoration: const BoxDecoration(
        color: CvColors.surface,
        border: Border(top: BorderSide(color: CvColors.border)),
      ),
      child: Row(
        children: [
          ?leading,
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: actions,
            ),
          ),
        ],
      ),
    );
  }
}

/// Acción secundaria del pie («Cancelar»).
class FormCancelButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;

  const FormCancelButton({super.key, required this.onPressed, this.label = 'Cancelar'});

  @override
  Widget build(BuildContext context) => CvSecondaryButton(label: label, onPressed: onPressed);
}

// =====================================================================
// Selector con búsqueda
// =====================================================================

/// Selector con búsqueda sobre una lista (clientes, productos...).
Future<T?> showSearchPicker<T>(
  BuildContext context, {
  required String title,
  required List<T> items,
  required String Function(T) labelOf,
  String hint = 'Buscar...',
}) {
  return showDialog<T>(
    context: context,
    barrierColor: CvColors.textPrimary.withValues(alpha: 0.32),
    builder: (_) => Theme(
      data: cvFormTheme,
      child: _SearchPicker<T>(title: title, items: items, labelOf: labelOf, hint: hint),
    ),
  );
}

class _SearchPicker<T> extends StatefulWidget {
  final String title;
  final List<T> items;
  final String Function(T) labelOf;
  final String hint;

  const _SearchPicker({required this.title, required this.items, required this.labelOf, required this.hint});

  @override
  State<_SearchPicker<T>> createState() => _SearchPickerState<T>();
}

class _SearchPickerState<T> extends State<_SearchPicker<T>> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static String _fold(String s) {
    const from = 'áàäâéèëêíìïîóòöôúùüûñç';
    const to = 'aaaaeeeeiiiioooouuuunc';
    final lower = s.toLowerCase();
    final buffer = StringBuffer();
    for (final ch in lower.split('')) {
      final i = from.indexOf(ch);
      buffer.write(i >= 0 ? to[i] : ch);
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final needle = _fold(_query.trim());
    final filtered = needle.isEmpty
        ? widget.items
        : widget.items.where((i) => _fold(widget.labelOf(i)).contains(needle)).toList();
    final size = MediaQuery.sizeOf(context);
    final fullScreen = size.width < 600;

    final content = Column(
      mainAxisSize: fullScreen ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: widget.title,
          onClose: () => Navigator.pop(context),
          padding: EdgeInsets.fromLTRB(fullScreen ? 20 : 24, fullScreen ? 8 : 18, 12, 12),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: fullScreen ? 16 : 20),
          child: CvSearchField(
            controller: _search,
            hint: widget.hint,
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
            onClear: () => setState(() {
              _search.clear();
              _query = '';
            }),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(fullScreen ? 20 : 24, CvSpace.md, 20, CvSpace.xs),
          child: Text(
            filtered.isEmpty
                ? 'Sin resultados'
                : (needle.isEmpty ? 'Resultados' : '${filtered.length} resultado${filtered.length == 1 ? '' : 's'}'),
            style: CvText.helper.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
        Flexible(
          fit: fullScreen ? FlexFit.tight : FlexFit.loose,
          child: filtered.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(24, CvSpace.lg, 24, CvSpace.xxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.search_off_rounded, size: 26, color: CvColors.textPlaceholder),
                      const SizedBox(height: CvSpace.xs),
                      Text('No hay coincidencias para «${_query.trim()}».',
                          textAlign: TextAlign.center, style: CvText.body.copyWith(fontSize: 14)),
                    ],
                  ),
                )
              : ListView.builder(
                  shrinkWrap: !fullScreen,
                  padding: const EdgeInsets.fromLTRB(CvSpace.xs, 0, CvSpace.xs, CvSpace.sm),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _PickerRow(
                    label: widget.labelOf(filtered[i]),
                    onTap: () => Navigator.pop(context, filtered[i]),
                  ),
                ),
        ),
      ],
    );

    if (fullScreen) {
      return Dialog.fullscreen(
        backgroundColor: CvColors.surface,
        child: SafeArea(child: content),
      );
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 500, maxHeight: size.height * 0.78),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CvColors.surface,
            borderRadius: BorderRadius.circular(CvRadius.card),
            border: Border.all(color: CvColors.border),
            boxShadow: CvShadows.panel,
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(CvRadius.card), child: content),
        ),
      ),
    );
  }
}

/// Resultado del selector: fila amplia, hover suave y chevron discreto.
class _PickerRow extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _PickerRow({required this.label, required this.onTap});

  @override
  State<_PickerRow> createState() => _PickerRowState();
}

class _PickerRowState extends State<_PickerRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        borderRadius: BorderRadius.circular(CvRadius.sm),
        hoverColor: CvColors.background,
        highlightColor: CvColors.primarySoft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: CvSpace.md - 2, vertical: CvSpace.sm - 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.label, style: const TextStyle(fontSize: 15, color: CvColors.textPrimary)),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _hover ? 1 : 0,
                  child: const Icon(Icons.chevron_right_rounded, size: 20, color: CvColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
