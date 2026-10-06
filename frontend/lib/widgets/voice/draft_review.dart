// Revisión de un borrador del Action Engine (H.4, Voice V2).
//
// transcripción -> borrador del servidor -> revisión editable -> confirmar.
// El servidor es la única autoridad: resuelve entidades (ids, candidatos,
// coincidencias aproximadas), calcula los issues y decide si es confirmable.
// Aquí solo se muestran y se envían ediciones TIPADAS (PATCH con la
// revisión vista). Confirmar envía únicamente {revision}.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_colors.dart';
import '../../core/money.dart';
import '../../models/action_draft.dart';
import '../../models/crm.dart';
import '../../services/api_service.dart';
import '../crm/crm_ui.dart';
import '../crm/form_shell.dart';
import '../crm/sale_form.dart' show maxSaleLines;

enum VoiceNavTarget { clientDetail, history }

/// Lo que devuelve la revisión al cerrarse tras confirmar.
class VoiceReviewOutcome {
  final ActionResult result;
  final VoiceNavTarget? target;

  const VoiceReviewOutcome(this.result, {this.target});
}

Future<VoiceReviewOutcome?> openDraftReview(BuildContext context, {required ActionDraft draft}) =>
    openCrmForm<VoiceReviewOutcome>(context, DraftReview(initialDraft: draft));

enum _Phase { review, patching, reinterpreting, confirming, cancelling, success, closed }

class DraftReview extends StatefulWidget {
  final ActionDraft initialDraft;

  const DraftReview({super.key, required this.initialDraft});

  @override
  State<DraftReview> createState() => _DraftReviewState();
}

class _DraftReviewState extends State<DraftReview> {
  late ActionDraft _draft = widget.initialDraft;
  late final TextEditingController _transcript = TextEditingController(text: widget.initialDraft.sourceText);
  bool _editingTranscript = false;
  _Phase _phase = _Phase.review;
  String? _error;
  List<String> _errorDetails = const [];
  String? _closedMessage;
  ActionResult? _result;

  /// El usuario ha cambiado algo (ediciones o transcripción reinterpretada).
  bool _touched = false;

  bool get _busy => const {_Phase.patching, _Phase.reinterpreting, _Phase.confirming, _Phase.cancelling}
      .contains(_phase);

  ApiService get _api => context.read<ApiService>();

  @override
  void dispose() {
    _transcript.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Llamadas al servidor
  // ------------------------------------------------------------------

  void _setError(String? message, [List<String> details = const []]) {
    _error = message;
    _errorDetails = details;
  }

  /// Traduce un error de borrador. Si el servidor manda el borrador
  /// actualizado (409 stale, 422 al confirmar...), se muestra ese.
  void _handleDraftError(ApiException e, {String? networkHint}) {
    final fresh = ActionDraft.tryParse(e.body['draft']);
    setState(() {
      _phase = _Phase.review;
      if (fresh != null) _draft = fresh;
      if (fresh != null && fresh.isExecuted && fresh.result != null) {
        _result = fresh.result;
        _phase = _Phase.success;
        _setError(null);
        return;
      }
      switch (e.kind) {
        case ApiErrorKind.gone:
          _phase = _Phase.closed;
          _closedMessage = e.message;
        case ApiErrorKind.notFound:
          _phase = _Phase.closed;
          _closedMessage = 'Este borrador ya no existe. Vuelve a dictar la acción.';
        case ApiErrorKind.conflict when e.code == 'draft_cancelled':
          _phase = _Phase.closed;
          _closedMessage = 'Este borrador se canceló.';
        case ApiErrorKind.network:
          _setError(networkHint ?? e.message);
        default:
          final detail = e.body['detail'];
          _setError(detail is String ? detail : e.message, e.issueMessages);
      }
    });
  }

  Future<void> _patch(Map<String, dynamic> edits) async {
    if (_busy || !_draft.isOpen) return;
    setState(() {
      _phase = _Phase.patching;
      _setError(null);
    });
    try {
      final updated = await _api.patchDraft(_draft.id, _draft.revision, edits);
      if (!mounted) return;
      setState(() {
        _draft = updated;
        _touched = true;
        _phase = _Phase.review;
      });
    } on ApiException catch (e) {
      if (mounted) _handleDraftError(e);
    }
  }

  Future<void> _confirm() async {
    if (_busy || !_draft.confirmable) return;
    setState(() {
      _phase = _Phase.confirming;
      _setError(null);
    });
    try {
      final outcome = await _api.confirmDraft(_draft.id, _draft.revision);
      if (!mounted) return;
      setState(() {
        if (outcome.draft != null) _draft = outcome.draft!;
        _result = outcome.result ?? outcome.draft?.result;
        _phase = _result != null ? _Phase.success : _Phase.review;
        if (_result == null) _setError('Respuesta no válida del servidor.');
      });
    } on ApiException catch (e) {
      if (mounted) {
        _handleDraftError(e,
            networkHint: 'No se ha podido confirmar (sin respuesta del servidor). Puedes reintentar: '
                'si ya se había guardado, no se duplicará.');
      }
    }
  }

  Future<void> _reinterpret() async {
    final text = _transcript.text.trim();
    if (_busy) return;
    if (text.isEmpty) {
      setState(() => _setError('Escribe qué quieres hacer.'));
      return;
    }
    setState(() {
      _phase = _Phase.reinterpreting;
      _setError(null);
    });
    final previous = _draft;
    try {
      final fresh = await _api.interpretText(text);
      if (!mounted) return;
      setState(() {
        _draft = fresh;
        _editingTranscript = false;
        _touched = true;
        _phase = _Phase.review;
      });
      // El borrador anterior queda sustituido: se cancela (si falla, caduca solo)
      if (previous.isOpen) unawaited(_api.cancelDraft(previous.id).then((_) {}, onError: (_) {}));
    } on ApiException catch (e) {
      if (!mounted) return;
      // Se conserva el texto corregido y el borrador anterior
      setState(() {
        _phase = _Phase.review;
        _setError(e.message);
      });
    }
  }

  Future<void> _requestClose() async {
    if (_busy) return;
    if (_phase == _Phase.success) {
      Navigator.pop(context, VoiceReviewOutcome(_result!));
      return;
    }
    if (_phase == _Phase.closed || !_draft.isOpen) {
      Navigator.pop(context);
      return;
    }
    final changed = _touched || _transcript.text.trim() != _draft.sourceText.trim();
    if (changed) {
      final discard = await confirmDestructive(
        context,
        title: 'Descartar la acción',
        message: 'Se perderán los cambios y no se guardará nada en el CRM.',
        confirmLabel: 'Descartar',
      );
      if (!discard || !mounted) return;
    }
    setState(() => _phase = _Phase.cancelling);
    try {
      await _api.cancelDraft(_draft.id);
    } on ApiException catch (e) {
      final fresh = ActionDraft.tryParse(e.body['draft']);
      if (fresh != null && fresh.isExecuted && fresh.result != null && mounted) {
        // Ya se había confirmado (p. ej. en otra pestaña): no se puede cancelar
        setState(() {
          _draft = fresh;
          _result = fresh.result;
          _phase = _Phase.success;
        });
        return;
      }
      // Caducado, inexistente o sin red: no queda nada que guardar; caducará solo
    }
    if (mounted) {
      showSuccess(context, 'Acción descartada: no se ha guardado nada');
      Navigator.pop(context);
    }
  }

  // ------------------------------------------------------------------
  // Ediciones tipadas
  // ------------------------------------------------------------------

  Future<void> _search(String title, Future<List<CatalogItem>> Function() load, void Function(CatalogItem) onPick) async {
    List<CatalogItem> items;
    try {
      items = await load();
    } catch (e) {
      if (mounted) showFailure(context, userMessage(e));
      return;
    }
    if (!mounted) return;
    final picked = await showSearchPicker<CatalogItem>(context,
        title: title, items: items, labelOf: (i) => i.name, hint: 'Buscar...');
    if (picked != null && mounted) onPick(picked);
  }

  Future<String?> _askText(String label, String? current, {int maxLength = 120, bool multiline = false}) =>
      showDialog<String>(
        context: context,
        builder: (_) => CrmTheme(
          child: _TextEditDialog(label: label, initial: current, maxLength: maxLength, multiline: multiline),
        ),
      );

  Future<void> _editText(String key, String label, {int maxLength = 120, bool multiline = false}) async {
    final value = await _askText(label, _draft.text(key), maxLength: maxLength, multiline: multiline);
    if (value == null || !mounted) return;
    final clean = value.trim();
    if (clean == (_draft.text(key) ?? '')) return;
    await _patch({key: clean.isEmpty ? null : clean});
  }

  void _pickClient() => _search('Seleccionar cliente', _api.clientItems, (c) => _patch({'client_id': c.id}));

  void _pickContact() {
    final client = _draft.ref('client');
    if (client == null || !client.resolved) {
      showFailure(context, 'Elige primero el cliente.');
      return;
    }
    _search('Seleccionar contacto', () => _api.contactItems(client.id!), (c) => _patch({'contact_id': c.id}));
  }

  /// Productos de una actividad: ids si todos están resueltos; si no, nombres
  /// (oficial o dicho) para que el servidor vuelva a resolver los pendientes.
  Map<String, dynamic> _productEdit(List<({int? id, String? name})> items) {
    if (items.every((p) => p.id != null)) return {'product_ids': items.map((p) => p.id).toList()};
    return {'product_names': items.map((p) => p.name ?? '').where((n) => n.isNotEmpty).toList()};
  }

  List<({int? id, String? name})> _currentProducts() => _draft.products
      .map((p) => (id: p.resolved ? p.id : null, name: p.resolved ? p.label : p.said))
      .toList();

  void _setProduct(int index, CatalogItem chosen) {
    final items = _currentProducts();
    items[index] = (id: chosen.id, name: chosen.name);
    _patch(_productEdit(items));
  }

  void _removeProduct(int index) {
    final items = _currentProducts()..removeAt(index);
    _patch(_productEdit(items));
  }

  void _addProduct() => _search('Añadir producto', _api.productItems, (p) {
        final items = _currentProducts()..add((id: p.id, name: p.name));
        _patch(_productEdit(items));
      });

  /// Líneas de venta tal como están, en el formato de edición (SaleLineEdit).
  List<Map<String, dynamic>> _lineEdits() => _draft.lines.map((l) {
        final p = l.product;
        return <String, dynamic>{
          if (p != null && p.resolved) 'product_id': p.id,
          if (p != null && !p.resolved && p.said != null) 'product_name': p.said,
          if (l.concept != null) 'concept': l.concept,
          if (l.quantity != null) 'quantity': l.quantity,
          'amount': l.amountError != null
              ? l.amountSaid
              : (l.amountCents != null ? centsToInput(l.amountCents!) : null),
        };
      }).toList();

  void _setLineProduct(int index, CatalogItem chosen) {
    final lines = _lineEdits();
    lines[index] = {...lines[index]..remove('product_name'), 'product_id': chosen.id};
    _patch({'lines': lines});
  }

  void _removeLine(int index) {
    final lines = _lineEdits()..removeAt(index);
    if (lines.isEmpty) return;
    _patch({'lines': lines});
  }

  Future<void> _editLine(int? index) async {
    final lines = _lineEdits();
    final current = index == null ? null : _draft.lines[index];
    final edited = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => CrmTheme(child: _SaleLineDialog(line: current, loadProducts: _api.productItems)),
    );
    if (edited == null || !mounted) return;
    if (index == null) {
      lines.add(edited);
    } else {
      lines[index] = edited;
    }
    await _patch({'lines': lines});
  }

  Future<void> _pickDate(String key) async {
    final current = DateTime.tryParse(_draft.text(key) ?? '') ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) await _patch({key: formatApiDate(picked)});
  }

  Future<void> _pickTime() async {
    final parts = (_draft.text('time') ?? '').split(':');
    final initial = parts.length >= 2 && int.tryParse(parts[0]) != null && int.tryParse(parts[1]) != null
        ? TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]))
        : TimeOfDay.now();
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null && mounted) await _patch({'time': '${two(picked.hour)}:${two(picked.minute)}'});
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final title = switch (_phase) {
      _Phase.success => 'Guardado',
      _Phase.closed => 'Acción no disponible',
      _ => '${_draft.type.label} · revisión',
    };
    return CrmFormShell(
      title: title,
      maxWidth: 720,
      busy: _busy,
      onClose: _requestClose,
      actions: _actions(),
      body: switch (_phase) {
        _Phase.success => _successView(),
        _Phase.closed => _closedView(),
        _ => _reviewView(),
      },
    );
  }

  List<Widget> _actions() {
    if (_phase == _Phase.success) {
      final r = _result!;
      return [
        if (r.entity == 'activity')
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, VoiceReviewOutcome(r, target: VoiceNavTarget.history)),
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('Ver en Histórico'),
          ),
        if (r.clientId != null)
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, VoiceReviewOutcome(r, target: VoiceNavTarget.clientDetail)),
            icon: const Icon(Icons.business),
            label: const Text('Abrir ficha del cliente'),
          ),
        FilledButton(onPressed: () => Navigator.pop(context, VoiceReviewOutcome(r)), child: const Text('Hecho')),
      ];
    }
    if (_phase == _Phase.closed) {
      return [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))];
    }
    final confirming = _phase == _Phase.confirming;
    return [
      TextButton(onPressed: _busy ? null : _requestClose, child: const Text('Descartar')),
      FilledButton.icon(
        key: const Key('voice-confirm'),
        onPressed: _busy || !_draft.confirmable || _editingTranscript ? null : _confirm,
        icon: confirming
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.check),
        label: Text(confirming ? 'Guardando...' : 'Confirmar y guardar'),
      ),
    ];
  }

  Widget _closedView() => EmptyView(icon: Icons.timer_off_outlined, message: _closedMessage ?? 'Acción no disponible.');

  Widget _successView() {
    final r = _result!;
    final what = switch (r.entity) {
      'activity' => 'Actividad creada',
      'client' => 'Cliente creado',
      'contact' => 'Contacto creado',
      'sale' => r.ids.length > 1 ? 'Venta registrada (${r.ids.length} líneas)' : 'Venta registrada',
      _ => 'Acción guardada',
    };
    final data = r.data;
    String? detail;
    if (data is Map) {
      detail = [
        if (data['name'] is String) data['name'],
        if (data['activity_type'] is String) data['activity_type'],
        if (data['datetime'] is String) formatDateTime(DateTime.tryParse(data['datetime'])),
        if (r.entity != 'client' && r.clientName != null) r.clientName,
      ].join(' · ');
    } else if (data is List) {
      final total = data.whereType<Map>().fold<int>(0, (s, l) => s + ((l['amount_cents'] as num?)?.toInt() ?? 0));
      detail = [if (r.clientName != null) r.clientName!, formatEuros(total)].join(' · ');
    }
    return Column(
      children: [
        const Icon(Icons.check_circle, size: 56, color: Color(0xFF15803D)),
        const SizedBox(height: 12),
        Text(what, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        if (detail != null && detail.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(detail, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
        ],
        const SizedBox(height: 8),
        const Text('Guardado en el CRM tras tu confirmación.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _reviewView() {
    final d = _draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy && _phase != _Phase.confirming) const LinearProgressIndicator(minHeight: 2),
        _transcriptCard(),
        const SizedBox(height: 12),
        if (_error != null) FormErrorBanner(message: _error!, details: _errorDetails),
        _issuesSummary(d),
        ...switch (d.type) {
          ActionType.createActivity => _activityFields(d),
          ActionType.createClient => _clientFields(d),
          ActionType.createContact => _contactFields(d),
          ActionType.createSale => _saleFields(d),
        },
      ],
    );
  }

  Widget _transcriptCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.record_voice_over_outlined, size: 18, color: AppColors.primary),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Has dicho', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.primary)),
              ),
              if (!_editingTranscript)
                TextButton.icon(
                  onPressed: _busy ? null : () => setState(() => _editingTranscript = true),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Corregir texto'),
                ),
            ],
          ),
          if (_editingTranscript) ...[
            TextField(
              key: const Key('voice-transcript-field'),
              controller: _transcript,
              minLines: 2,
              maxLines: 5,
              maxLength: 2000,
              enabled: !_busy,
              decoration: const InputDecoration(helperText: 'Corrige lo que se haya entendido mal y reinterpreta.'),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _editingTranscript = false;
                            _transcript.text = _draft.sourceText;
                          }),
                  child: const Text('Cancelar'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _reinterpret,
                  icon: _phase == _Phase.reinterpreting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_fix_high),
                  label: const Text('Reinterpretar'),
                ),
              ],
            ),
          ] else
            SelectableText('«${_draft.sourceText}»', style: const TextStyle(fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }

  Widget _issuesSummary(ActionDraft d) {
    final blocking = d.blockingIssues;
    if (blocking.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Icon(Icons.verified_outlined, color: Color(0xFF15803D), size: 20),
            SizedBox(width: 6),
            Expanded(child: Text('Listo para confirmar. Revisa los datos antes de guardar.')),
          ],
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFB91C1C).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFB91C1C).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Para poder confirmar, resuelve ${blocking.length == 1 ? 'esto' : 'estos ${blocking.length} puntos'}:',
              style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w600)),
          for (final i in blocking)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('• ${describeIssue(i)}', style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13)),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------- por acción

  List<Widget> _activityFields(ActionDraft d) {
    final status = d.text('status');
    final products = d.products;
    return [
      _RefRow(
        label: 'Cliente',
        ref: d.ref('client'),
        issues: d.issuesFor('client'),
        enabled: !_busy,
        onCandidate: (c) => _patch({'client_id': c.id}),
        onSearch: _pickClient,
      ),
      _RefRow(
        label: 'Contacto',
        ref: d.ref('contact'),
        issues: d.issuesFor('contact'),
        enabled: !_busy,
        onCandidate: (c) => _patch({'contact_id': c.id}),
        onSearch: _pickContact,
        onClear: d.ref('contact') == null ? null : () => _patch({'contact_id': null}),
      ),
      _RefRow(
        label: 'Tipo de actividad',
        ref: d.ref('activity_type'),
        issues: d.issuesFor('activity_type'),
        enabled: !_busy,
        onCandidate: (c) => _patch({'activity_type_id': c.id}),
        onSearch: () => _search('Tipo de actividad', _api.activityTypeItems, (t) => _patch({'activity_type_id': t.id})),
      ),
      _ValueRow(
        label: 'Fecha',
        value: formatIsoDate(d.text('date')),
        issues: d.issuesFor('date'),
        enabled: !_busy,
        onEdit: () => _pickDate('date'),
        editIcon: Icons.calendar_today,
      ),
      _ValueRow(
        label: 'Hora',
        value: d.text('time') ?? '—',
        issues: d.issuesFor('time'),
        enabled: !_busy,
        onEdit: _pickTime,
        editIcon: Icons.access_time,
      ),
      _FieldBlock(
        label: 'Estado',
        issues: d.issuesFor('status'),
        child: Wrap(
          spacing: 8,
          children: [
            for (final s in const [('pending', 'Pendiente'), ('completed', 'Completada')])
              ChoiceChip(
                label: Text(s.$2),
                selected: status == s.$1,
                onSelected: _busy || status == s.$1 ? null : (_) => _patch({'status': s.$1}),
              ),
          ],
        ),
      ),
      _FieldBlock(
        label: 'Productos',
        issues: d.issuesFor('products'),
        trailing: TextButton.icon(
          onPressed: _busy || products.length >= 10 ? null : _addProduct,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Añadir'),
        ),
        child: products.isEmpty
            ? const Text('Sin productos', style: TextStyle(color: AppColors.textSecondary))
            : Column(
                children: [
                  for (var i = 0; i < products.length; i++)
                    _RefRow(
                      label: 'Producto ${i + 1}',
                      ref: products[i],
                      issues: d.issuesFor('products[$i]'),
                      enabled: !_busy,
                      dense: true,
                      onCandidate: (c) => _setProduct(i, c),
                      onSearch: () => _search('Producto', _api.productItems, (p) => _setProduct(i, p)),
                      onClear: () => _removeProduct(i),
                    ),
                ],
              ),
      ),
      _ValueRow(
        label: 'Comentario',
        value: d.text('comment') ?? '—',
        issues: d.issuesFor('comment'),
        enabled: !_busy,
        onEdit: () => _editText('comment', 'Comentario', maxLength: 2000, multiline: true),
      ),
      ..._otherIssues(d, const {'client', 'contact', 'activity_type', 'date', 'time', 'status', 'products', 'comment'}),
    ];
  }

  List<Widget> _clientFields(ActionDraft d) {
    final group = d.ref('group');
    return [
      for (final f in const [('name', 'Razón social'), ('alias', 'Alias'), ('city', 'Población'), ('province', 'Provincia')])
        _ValueRow(
          label: f.$2,
          value: d.text(f.$1) ?? '—',
          issues: d.issuesFor(f.$1),
          enabled: !_busy,
          onEdit: () => _editText(f.$1, f.$2, maxLength: f.$1 == 'alias' ? 60 : (f.$1 == 'name' ? 120 : 80)),
        ),
      if (group != null)
        _RefRow(
          label: 'Grupo',
          ref: group,
          issues: d.issuesFor('group'),
          enabled: !_busy,
          onClear: () => _patch({'group_id': null}),
          note: 'El grupo solo se puede quitar aquí (la app aún no tiene selector de grupos).',
        ),
      ..._otherIssues(d, const {'name', 'alias', 'city', 'province', 'group'}),
    ];
  }

  List<Widget> _contactFields(ActionDraft d) {
    return [
      _RefRow(
        label: 'Cliente',
        ref: d.ref('client'),
        issues: d.issuesFor('client'),
        enabled: !_busy,
        onCandidate: (c) => _patch({'client_id': c.id}),
        onSearch: _pickClient,
      ),
      for (final f in const [('name', 'Nombre'), ('role', 'Cargo'), ('email', 'Email'), ('phone', 'Teléfono')])
        _ValueRow(
          label: f.$2,
          value: d.text(f.$1) ?? '—',
          issues: d.issuesFor(f.$1),
          enabled: !_busy,
          onEdit: () => _editText(f.$1, f.$2, maxLength: f.$1 == 'email' ? 120 : 80),
        ),
      ..._otherIssues(d, const {'client', 'name', 'role', 'email', 'phone'}),
    ];
  }

  List<Widget> _saleFields(ActionDraft d) {
    final lines = d.lines;
    final total = d.saleTotalCents;
    return [
      _RefRow(
        label: 'Cliente',
        ref: d.ref('client'),
        issues: d.issuesFor('client'),
        enabled: !_busy,
        onCandidate: (c) => _patch({'client_id': c.id}),
        onSearch: _pickClient,
      ),
      _RefRow(
        label: 'Contacto',
        ref: d.ref('contact'),
        issues: d.issuesFor('contact'),
        enabled: !_busy,
        onCandidate: (c) => _patch({'contact_id': c.id}),
        onSearch: _pickContact,
        onClear: d.ref('contact') == null ? null : () => _patch({'contact_id': null}),
      ),
      _ValueRow(
        label: 'Fecha de venta',
        value: formatIsoDate(d.text('sale_date')),
        issues: d.issuesFor('sale_date'),
        enabled: !_busy,
        onEdit: () => _pickDate('sale_date'),
        editIcon: Icons.calendar_today,
      ),
      _FieldBlock(
        label: 'Líneas (${lines.length})',
        issues: d.issuesFor('lines'),
        trailing: TextButton.icon(
          onPressed: _busy || lines.length >= maxSaleLines ? null : () => _editLine(null),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Añadir línea'),
        ),
        child: Column(
          children: [
            for (var i = 0; i < lines.length; i++) _saleLine(d, i, lines[i], canRemove: lines.length > 1),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))),
                  Text(total == null ? 'Falta algún importe' : formatEuros(total),
                      key: const Key('voice-sale-total'), style: const TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
      _ValueRow(
        label: 'Notas',
        value: d.text('notes') ?? '—',
        issues: d.issuesFor('notes'),
        enabled: !_busy,
        onEdit: () => _editText('notes', 'Notas', maxLength: 500, multiline: true),
      ),
      ..._otherIssues(d, const {'client', 'contact', 'sale_date', 'lines', 'notes'}, prefix: 'lines['),
    ];
  }

  Widget _saleLine(ActionDraft d, int i, SaleLineDraft line, {required bool canRemove}) {
    final p = line.product;
    final amountIssues = d.issuesFor('lines[$i].amount');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 8),
      decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Línea ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700))),
              IconButton(
                tooltip: 'Editar línea ${i + 1}',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: _busy ? null : () => _editLine(i),
              ),
              IconButton(
                tooltip: 'Quitar línea ${i + 1}',
                icon: const Icon(Icons.remove_circle_outline, size: 20),
                onPressed: _busy || !canRemove ? null : () => _removeLine(i),
              ),
            ],
          ),
          if (p != null)
            _RefRow(
              label: 'Producto',
              ref: p,
              issues: d.issuesFor('lines[$i].product'),
              enabled: !_busy,
              dense: true,
              onCandidate: (c) => _setLineProduct(i, c),
              onSearch: () => _search('Producto', _api.productItems, (c) => _setLineProduct(i, c)),
            )
          else
            _ValueRow(
              label: 'Concepto',
              value: line.concept ?? '—',
              issues: d.issuesFor('lines[$i].product'),
              enabled: !_busy,
              onEdit: () => _editLine(i),
            ),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text('Cantidad: ${line.quantity ?? '—'}'),
              Text(
                'Importe: ${line.amountCents != null ? formatEuros(line.amountCents!) : (line.amountSaid ?? '—')}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (line.referenceTotalCents != null)
                Text('PVP de catálogo: ${formatEuros(line.referenceTotalCents!)} (solo orientativo)',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
          for (final issue in amountIssues) _IssueText(issue),
        ],
      ),
    );
  }

  /// Issues que no corresponden a ningún campo mostrado (p. ej. duplicados).
  List<Widget> _otherIssues(ActionDraft d, Set<String> shown, {String? prefix}) {
    final rest = d.issues
        .where((i) => !shown.contains(i.field) && !RegExp(r'^products\[\d+\]$').hasMatch(i.field))
        .where((i) => prefix == null || !i.field.startsWith(prefix))
        .toList();
    if (rest.isEmpty) return const [];
    return [
      _FieldBlock(label: 'Otros avisos', issues: rest, child: const SizedBox.shrink()),
    ];
  }
}

// =====================================================================
// Piezas de la revisión
// =====================================================================

const _red = Color(0xFFB91C1C);
const _amber = Color(0xFFB45309);
const _green = Color(0xFF15803D);

class _IssueText extends StatelessWidget {
  final ApiIssue issue;

  const _IssueText(this.issue);

  @override
  Widget build(BuildContext context) {
    final color = issue.blocking ? _red : _amber;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(issue.blocking ? Icons.error_outline : Icons.info_outline, size: 16, color: color),
          const SizedBox(width: 4),
          Expanded(child: Text(issue.message, style: TextStyle(fontSize: 12.5, color: color))),
        ],
      ),
    );
  }
}

class _FieldBlock extends StatelessWidget {
  final String label;
  final List<ApiIssue> issues;
  final Widget child;
  final Widget? trailing;

  const _FieldBlock({required this.label, required this.issues, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 4),
          child,
          for (final i in issues) _IssueText(i),
        ],
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  final String label;
  final String value;
  final List<ApiIssue> issues;
  final bool enabled;
  final VoidCallback onEdit;
  final IconData editIcon;

  const _ValueRow({
    required this.label,
    required this.value,
    required this.issues,
    required this.enabled,
    required this.onEdit,
    this.editIcon = Icons.edit_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return _FieldBlock(
      label: label,
      issues: issues,
      child: Row(
        children: [
          Expanded(child: Text(value, style: const TextStyle(fontSize: 15))),
          IconButton(
            tooltip: 'Cambiar ${label.toLowerCase()}',
            icon: Icon(editIcon, size: 20),
            onPressed: enabled ? onEdit : null,
          ),
        ],
      ),
    );
  }
}

/// Entidad resuelta por el servidor: nombre oficial, lo dicho, tipo de
/// coincidencia, problema y candidatos (todo viene del borrador).
class _RefRow extends StatelessWidget {
  final String label;
  final ResolvedRef? ref;
  final List<ApiIssue> issues;
  final bool enabled;
  final bool dense;
  final void Function(CatalogItem)? onCandidate;
  final VoidCallback? onSearch;
  final VoidCallback? onClear;
  final String? note;

  const _RefRow({
    required this.label,
    required this.ref,
    required this.issues,
    required this.enabled,
    this.dense = false,
    this.onCandidate,
    this.onSearch,
    this.onClear,
    this.note,
  });

  static (String, Color)? badge(ResolvedRef r) {
    switch (r.problem) {
      case 'ambiguous':
        return ('Ambiguo: elige uno', _red);
      case 'not_found':
        return ('No encontrado', _red);
      case 'conflict':
        return ('No encaja', _red);
    }
    if (r.id == null) return ('Sin resolver', _red);
    return switch (r.match) {
      'exact' => ('Coincidencia exacta', _green),
      'fuzzy' || 'partial' => ('Coincidencia aproximada', _amber),
      'inherited' => ('Deducido del contacto', _amber),
      'user_selected' => ('Elegido por ti', _green),
      'new' => ('Nuevo', _green),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final r = ref;
    final b = r == null ? null : badge(r);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    r == null ? '—' : (r.resolved ? r.display : '«${r.display}»'),
                    style: TextStyle(fontSize: 15, fontWeight: r?.resolved == true ? FontWeight.w600 : FontWeight.w400),
                  ),
                  if (b != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: b.$2.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(b.$1, style: TextStyle(fontSize: 11.5, color: b.$2, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
            if (onSearch != null)
              IconButton(
                tooltip: 'Buscar ${label.toLowerCase()} en el CRM',
                icon: const Icon(Icons.search, size: 20),
                onPressed: enabled ? onSearch : null,
              ),
            if (onClear != null)
              IconButton(
                tooltip: 'Quitar ${label.toLowerCase()}',
                icon: const Icon(Icons.close, size: 20),
                onPressed: enabled ? onClear : null,
              ),
          ],
        ),
        if (r != null && r.resolved && r.saidDiffers)
          Text('Dijiste «${r.said}»', style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
        if (r != null && r.candidates.isNotEmpty && !r.resolved && onCandidate != null) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final c in r.candidates)
                ActionChip(
                  avatar: const Icon(Icons.touch_app_outlined, size: 16),
                  label: Text(c.name),
                  onPressed: enabled ? () => onCandidate!(c) : null,
                ),
            ],
          ),
        ],
        if (note != null)
          Text(note!, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ],
    );
    if (dense) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [content, for (final i in issues) _IssueText(i)],
        ),
      );
    }
    return _FieldBlock(label: label, issues: issues, child: content);
  }
}

/// Edición de un campo de texto del borrador (dueña de su controlador).
class _TextEditDialog extends StatefulWidget {
  final String label;
  final String? initial;
  final int maxLength;
  final bool multiline;

  const _TextEditDialog({required this.label, this.initial, required this.maxLength, required this.multiline});

  @override
  State<_TextEditDialog> createState() => _TextEditDialogState();
}

class _TextEditDialogState extends State<_TextEditDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.label),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: widget.maxLength,
          minLines: widget.multiline ? 3 : 1,
          maxLines: widget.multiline ? 6 : 1,
          onSubmitted: widget.multiline ? null : (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('Aplicar')),
      ],
    );
  }
}

/// Edición de una línea de venta (formato SaleLineEdit). El importe va como
/// texto en euros: lo interpreta el servidor.
class _SaleLineDialog extends StatefulWidget {
  final SaleLineDraft? line;
  final Future<List<CatalogItem>> Function() loadProducts;

  const _SaleLineDialog({required this.line, required this.loadProducts});

  @override
  State<_SaleLineDialog> createState() => _SaleLineDialogState();
}

class _SaleLineDialogState extends State<_SaleLineDialog> {
  final _formKey = GlobalKey<FormState>();
  late CatalogItem? _product = widget.line?.product?.resolved == true
      ? CatalogItem(widget.line!.product!.id!, widget.line!.product!.label ?? '')
      : null;
  late final _concept = TextEditingController(
      text: widget.line?.concept ?? (widget.line?.product?.resolved == false ? widget.line?.product?.said : null));
  late final _quantity = TextEditingController(text: widget.line?.quantity?.toString());
  late final _amount = TextEditingController(
      text: widget.line == null
          ? null
          : (widget.line!.amountError != null
              ? widget.line!.amountSaid
              : (widget.line!.amountCents != null ? centsToInput(widget.line!.amountCents!) : null)));

  @override
  void dispose() {
    _concept.dispose();
    _quantity.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickProduct() async {
    List<CatalogItem> items;
    try {
      items = await widget.loadProducts();
    } catch (e) {
      if (mounted) showFailure(context, userMessage(e));
      return;
    }
    if (!mounted) return;
    final picked =
        await showSearchPicker<CatalogItem>(context, title: 'Producto', items: items, labelOf: (p) => p.name);
    if (picked != null) setState(() => _product = picked);
  }

  void _apply() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(context, <String, dynamic>{
      if (_product != null) 'product_id': _product!.id,
      if (_product == null) 'concept': _concept.text.trim(),
      if (_quantity.text.trim().isNotEmpty) 'quantity': int.parse(_quantity.text.trim()),
      'amount': _amount.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final cents = parseEuroCents(_amount.text);
    return AlertDialog(
      title: Text(widget.line == null ? 'Nueva línea' : 'Editar línea'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_product != null)
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Producto',
                      suffixIcon: IconButton(
                        tooltip: 'Quitar producto (usar concepto)',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _product = null),
                      ),
                    ),
                    child: Text(_product!.name),
                  )
                else
                  TextFormField(
                    controller: _concept,
                    maxLength: 200,
                    decoration: InputDecoration(
                      labelText: 'Concepto *',
                      helperText: 'Texto libre, o elige un producto del catálogo',
                      suffixIcon: IconButton(
                        tooltip: 'Elegir producto del catálogo',
                        icon: const Icon(Icons.inventory_2_outlined),
                        onPressed: _pickProduct,
                      ),
                    ),
                    validator: (v) => (v?.trim().isEmpty ?? true) ? 'Indica un producto o un concepto' : null,
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _quantity,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Cantidad'),
                  validator: (v) {
                    final t = v?.trim() ?? '';
                    if (t.isEmpty) return null;
                    final n = int.tryParse(t);
                    return n == null || n < 1 || n > 100000 ? 'Entero entre 1 y 100.000' : null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Importe total de la línea *',
                    suffixText: '€',
                    helperText: cents != null ? '= ${formatEuros(cents)}' : 'Ej.: 1500, 1.500 o 1.500,00',
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: validateEuroAmount,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _apply, child: const Text('Aplicar')),
      ],
    );
  }
}
