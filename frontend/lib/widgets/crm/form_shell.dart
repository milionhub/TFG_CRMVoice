// Presentación común de los formularios del CRM (H.3): diálogo centrado en
// escritorio y pantalla completa en móvil, con la acción de guardar siempre
// visible (fuera del área con scroll).
import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import 'crm_ui.dart';

const double _fullScreenBelow = 700;

/// Abre un formulario y devuelve lo que este pase a Navigator.pop.
Future<T?> openCrmForm<T>(BuildContext context, Widget form) {
  final fullScreen = MediaQuery.sizeOf(context).width < _fullScreenBelow;
  if (fullScreen) {
    return Navigator.of(context).push<T>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FormMode(fullScreen: true, child: CrmTheme(child: form)),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FormMode(fullScreen: false, child: CrmTheme(child: form)),
  );
}

class _FormMode extends InheritedWidget {
  final bool fullScreen;

  const _FormMode({required this.fullScreen, required super.child});

  @override
  bool updateShouldNotify(_FormMode oldWidget) => fullScreen != oldWidget.fullScreen;
}

/// Esqueleto de un formulario: título, cuerpo con scroll y acciones abajo.
class CrmFormShell extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  final double maxWidth;

  /// Guardando: no se puede cerrar (ni con la X ni con "atrás") hasta que
  /// responda el backend, para que quien abrió el formulario se entere.
  final bool busy;

  const CrmFormShell({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.maxWidth = 620,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final fullScreen = context.dependOnInheritedWidgetOfExactType<_FormMode>()?.fullScreen ?? true;
    final footer = actions.isEmpty
        ? null
        : Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
          );
    final scrollBody = SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 20), child: body);

    final close = busy ? null : () => Navigator.maybePop(context);

    if (fullScreen) {
      return PopScope(
        canPop: !busy,
        child: Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.white,
            title: Text(title),
            leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Cerrar', onPressed: close),
          ),
          body: SafeArea(child: scrollBody),
          bottomNavigationBar: footer == null ? null : SafeArea(child: footer),
        ),
      );
    }

    final height = MediaQuery.sizeOf(context).height;
    return PopScope(
      canPop: !busy,
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: height * 0.9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close), tooltip: 'Cerrar', onPressed: close),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(child: scrollBody),
              ?footer,
            ],
          ),
        ),
      ),
    );
  }
}

/// Campo de solo lectura con aspecto de campo de formulario (p. ej. el
/// cliente fijo de un contacto).
class ReadOnlyField extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;

  const ReadOnlyField({super.key, required this.label, required this.value, this.icon});

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: icon == null ? null : Icon(icon),
        filled: true,
        fillColor: AppColors.background,
        enabled: false,
      ),
      child: Text(value, style: const TextStyle(color: AppColors.textPrimary)),
    );
  }
}

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
    builder: (_) => CrmTheme(
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
  String _query = '';

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
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 480, maxHeight: height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(icon: const Icon(Icons.close), tooltip: 'Cerrar', onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(hintText: widget.hint, prefixIcon: const Icon(Icons.search)),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Sin resultados', style: TextStyle(color: AppColors.textSecondary)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        title: Text(widget.labelOf(filtered[i])),
                        onTap: () => Navigator.pop(context, filtered[i]),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
