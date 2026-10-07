// Revisión de un borrador del Action Engine (H.4, Voice V2).
//
// transcripción -> borrador del servidor -> revisión editable -> confirmar.
// El servidor es la única autoridad: resuelve entidades (ids, candidatos,
// coincidencias aproximadas), calcula los issues y decide si es confirmable.
// Aquí solo se muestran y se envían ediciones TIPADAS (PATCH con la
// revisión vista). Confirmar envía únicamente {revision}.
//
// I.6.4: presentación propia de «revisar antes de guardar» (review_parts.dart):
// identidad de onda, transcripción, estado global, filas de lo que se
// guardará con su coincidencia y candidatos. La lógica no cambia.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design/cv_theme.dart';
import '../../core/design/cv_tokens.dart';
import '../../core/money.dart';
import '../../models/action_draft.dart';
import '../../models/crm.dart';
import '../../services/api_service.dart';
import '../crm/crm_ui.dart';
import '../crm/form_shell.dart';
import '../crm/sale_form.dart' show maxSaleLines, SaleTotalBar;
import '../chat/chat_identity.dart' show ChatWaves;
import '../ui/cv_components.dart';
import '../ui/cv_feedback.dart';
import 'review_parts.dart';

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
      openCrmForm<String>(
          context, _TextEditDialog(label: label, initial: current, maxLength: maxLength, multiline: multiline));

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
    final edited = await openCrmForm<Map<String, dynamic>>(
        context, _SaleLineDialog(line: current, loadProducts: _api.productItems));
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
  // UI (I.6.4)
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final title = switch (_phase) {
      _Phase.success => 'Guardado en CRM',
      _Phase.closed => 'Acción no disponible',
      _ => 'Revisar antes de guardar',
    };
    return CrmFormShell(
      title: title,
      maxWidth: 720,
      busy: _busy,
      onClose: _requestClose,
      leading: _phase == _Phase.success || _phase == _Phase.closed
          ? null
          : TextButton(
              onPressed: _busy ? null : _requestClose,
              style: TextButton.styleFrom(
                foregroundColor: CvColors.textSecondary,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: CvSpace.sm),
              ),
              child: const Text('Descartar'),
            ),
      actions: _actions(),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        child: switch (_phase) {
          _Phase.success => KeyedSubtree(key: const ValueKey('success'), child: _successView()),
          _Phase.closed => KeyedSubtree(key: const ValueKey('closed'), child: _closedView()),
          _ => KeyedSubtree(key: const ValueKey('review'), child: _reviewView()),
        },
      ),
    );
  }

  List<Widget> _actions() {
    if (_phase == _Phase.success) {
      final r = _result!;
      return [
        if (r.entity == 'activity')
          CvSecondaryButton(
            label: 'Ver en Actividades',
            icon: Icons.event_note_outlined,
            onPressed: () => Navigator.pop(context, VoiceReviewOutcome(r, target: VoiceNavTarget.history)),
          ),
        if (r.clientId != null)
          CvSecondaryButton(
            label: 'Abrir ficha del cliente',
            icon: Icons.business_outlined,
            onPressed: () => Navigator.pop(context, VoiceReviewOutcome(r, target: VoiceNavTarget.clientDetail)),
          ),
        CvPrimaryButton(label: 'Hecho', onPressed: () => Navigator.pop(context, VoiceReviewOutcome(r))),
      ];
    }
    if (_phase == _Phase.closed) {
      return [CvPrimaryButton(label: 'Cerrar', onPressed: () => Navigator.pop(context))];
    }
    final confirming = _phase == _Phase.confirming;
    return [
      CvPrimaryButton(
        key: const Key('voice-confirm'),
        label: confirming ? 'Guardando...' : 'Confirmar y guardar',
        icon: Icons.check_rounded,
        loading: confirming,
        onPressed: _busy || !_draft.confirmable || _editingTranscript ? null : _confirm,
      ),
    ];
  }

  /// Cerrada (caducada, inexistente o cancelada): el motivo es el que dio el
  /// servidor; no se inventan otros.
  Widget _closedView() => Padding(
        padding: const EdgeInsets.symmetric(vertical: CvSpace.sm),
        child: CvStatePanel(
          icon: const Icon(Icons.timer_off_outlined),
          title: 'Esta acción ya no se puede revisar',
          message: _closedMessage ?? 'Acción no disponible.',
        ),
      );

  Widget _successView() {
    final r = _result!;
    final what = switch (r.entity) {
      'activity' => 'Actividad creada',
      'client' => 'Cliente creado',
      'contact' => 'Contacto creado',
      'sale' => r.ids.length > 1 ? 'Venta registrada (${r.ids.length} líneas)' : 'Venta registrada',
      'product' => _draft.type == ActionType.updateProduct ? 'Producto actualizado' : 'Producto creado',
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
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 6 * (1 - t)), child: child),
      ),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: CvSpace.lg),
          child: Column(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  const ChatWaves(height: 72),
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: CvColors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: CvFeedbackTone.success.border),
                      boxShadow: const [BoxShadow(color: Color(0x0D172033), blurRadius: 18, offset: Offset(0, 6))],
                    ),
                    child: Icon(Icons.check_rounded, size: 28, color: CvFeedbackTone.success.color),
                  ),
                ],
              ),
              const SizedBox(height: CvSpace.md),
              Text(what, textAlign: TextAlign.center, style: CvText.heading.copyWith(fontSize: 20, letterSpacing: -0.3)),
              if (detail != null && detail.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(detail, textAlign: TextAlign.center, style: CvText.body.copyWith(fontSize: 14.5)),
              ],
              const SizedBox(height: CvSpace.sm),
              Text('Guardado en el CRM tras tu confirmación.',
                  textAlign: TextAlign.center, style: CvText.helper.copyWith(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  /// Texto del proceso en curso (estados que ya existen).
  String? get _progressText => switch (_phase) {
        _Phase.patching => 'Actualizando la revisión…',
        _Phase.reinterpreting => 'Interpretando tu solicitud…',
        _Phase.cancelling => 'Descartando…',
        _ => null,
      };

  Widget _reviewView() {
    final d = _draft;
    final progress = _progressText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReviewIntro(actionLabel: d.type.label),
        const SizedBox(height: CvSpace.lg),
        _transcriptCard(),
        const SizedBox(height: CvSpace.md),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: progress == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: CvSpace.sm),
                  child: Semantics(
                    liveRegion: true,
                    label: progress,
                    excludeSemantics: true,
                    child: Row(
                      children: [
                        const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: CvSpace.xs),
                        Text(progress, style: CvText.helper.copyWith(fontSize: 13)),
                      ],
                    ),
                  ),
                ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: CvSpace.md),
            child: CvInlineAlert(message: _error!, details: _errorDetails),
          ),
        _issuesSummary(d),
        const SizedBox(height: CvSpace.xl),
        const ReviewEyebrow('Esto se guardará'),
        const SizedBox(height: CvSpace.xxs),
        ReviewGroup(
          children: switch (d.type) {
            ActionType.createActivity => _activityFields(d),
            ActionType.createClient => _clientFields(d),
            ActionType.createContact => _contactFields(d),
            ActionType.createSale => _saleFields(d),
            ActionType.createProduct => _productFields(d),
            ActionType.updateProduct => _productUpdateFields(d),
          },
        ),
      ],
    );
  }

  Widget _transcriptCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      decoration: BoxDecoration(
        color: CvColors.background,
        borderRadius: BorderRadius.circular(CvRadius.control + 2),
        border: Border.all(color: CvColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReviewEyebrow(
            'Has dicho',
            trailing: _editingTranscript
                ? null
                : ReviewEditButton(
                    tooltip: 'Corregir lo que se ha entendido',
                    label: 'Corregir texto',
                    onPressed: _busy ? null : () => setState(() => _editingTranscript = true),
                  ),
          ),
          if (_editingTranscript) ...[
            const SizedBox(height: CvSpace.xs),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextField(
                key: const Key('voice-transcript-field'),
                controller: _transcript,
                minLines: 2,
                maxLines: 5,
                maxLength: 2000,
                enabled: !_busy,
                decoration: const InputDecoration(
                  helperText: 'Corrige lo que se haya entendido mal: CRMVoice volverá a interpretarlo.',
                ),
              ),
            ),
            const SizedBox(height: CvSpace.xs),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: CvSpace.xs,
                runSpacing: CvSpace.xs,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _editingTranscript = false;
                              _transcript.text = _draft.sourceText;
                            }),
                    style: TextButton.styleFrom(foregroundColor: CvColors.textSecondary, minimumSize: const Size(0, 40)),
                    child: const Text('Cancelar'),
                  ),
                  CvSecondaryButton(
                    label: 'Reinterpretar',
                    icon: Icons.refresh_rounded,
                    tooltip: 'Volver a interpretar el texto corregido',
                    onPressed: _busy ? null : _reinterpret,
                  ),
                ],
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 8),
              child: SelectableText(
                '«${_draft.sourceText}»',
                style: const TextStyle(fontSize: 15.5, height: 1.5, fontStyle: FontStyle.italic, color: CvColors.textPrimary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _issuesSummary(ActionDraft d) {
    final blocking = d.blockingIssues;
    if (blocking.isEmpty) {
      return const ReviewStatusPanel(
        ready: true,
        title: 'Listo para guardar',
        message: 'CRMVoice ha encontrado toda la información necesaria. Revisa los datos antes de guardar.',
      );
    }
    return ReviewStatusPanel(
      ready: false,
      title: 'Necesita tu revisión',
      message: 'Para poder confirmar, resuelve ${blocking.length == 1 ? 'esto' : 'estos ${blocking.length} puntos'}:',
      points: [for (final i in blocking) describeIssue(i)],
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
        editIcon: Icons.calendar_today_outlined,
      ),
      _ValueRow(
        label: 'Hora',
        value: d.text('time') ?? '—',
        issues: d.issuesFor('time'),
        enabled: !_busy,
        onEdit: _pickTime,
        editIcon: Icons.access_time_rounded,
      ),
      ReviewRow(
        label: 'Estado',
        value: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: const [
              ButtonSegment(value: 'pending', label: Text('Pendiente')),
              ButtonSegment(value: 'completed', label: Text('Completada')),
            ],
            selected: {?status},
            onSelectionChanged: _busy
                ? null
                : (v) {
                    if (v.isNotEmpty && v.first != status) _patch({'status': v.first});
                  },
          ),
        ),
        below: [for (final i in d.issuesFor('status')) _IssueText(i)],
      ),
      ReviewRow(
        label: 'Productos',
        value: products.isEmpty ? const ReviewValue(null) : const SizedBox.shrink(),
        actions: [
          ReviewEditButton(
            tooltip: 'Añadir producto',
            label: 'Añadir',
            icon: Icons.add_rounded,
            onPressed: _busy || products.length >= 10 ? null : _addProduct,
          ),
        ],
        below: [
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
          for (final i in d.issuesFor('products')) _IssueText(i),
        ],
      ),
      _ValueRow(
        label: 'Comentario',
        value: d.text('comment') ?? '—',
        issues: d.issuesFor('comment'),
        enabled: !_busy,
        strong: false,
        onEdit: () => _editText('comment', 'Comentario', maxLength: 2000, multiline: true),
      ),
      ..._otherIssues(d, const {'client', 'contact', 'activity_type', 'date', 'time', 'status', 'products', 'comment'}),
    ];
  }

  List<Widget> _clientFields(ActionDraft d) {
    final group = d.ref('group');
    return [
      for (final f in const [
        ('name', 'Razón social', 120),
        ('alias', 'Alias', 60),
        ('city', 'Población', 80),
        ('province', 'Provincia', 80),
        ('phone', 'Teléfono', 30),
        ('email', 'Email', 120),
        ('cif', 'CIF', 20),
      ])
        _ValueRow(
          label: f.$2,
          value: d.text(f.$1) ?? '—',
          issues: d.issuesFor(f.$1),
          enabled: !_busy,
          onEdit: () => _editText(f.$1, f.$2, maxLength: f.$3),
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
      ..._otherIssues(d, const {'name', 'alias', 'city', 'province', 'phone', 'email', 'cif', 'group'}),
    ];
  }

  List<Widget> _contactFields(ActionDraft d) {
    return [
      _RefRow(
        label: 'Cliente',
        ref: d.ref('client'),
        issues: d.issuesFor('client'),
        enabled: !_busy,
        note: 'El contacto se añadirá a este cliente.',
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
        editIcon: Icons.calendar_today_outlined,
      ),
      _ValueRow(
        label: 'Notas',
        value: d.text('notes') ?? '—',
        issues: d.issuesFor('notes'),
        enabled: !_busy,
        strong: false,
        onEdit: () => _editText('notes', 'Notas', maxLength: 500, multiline: true),
      ),
      Padding(
        padding: const EdgeInsets.only(top: CvSpace.md, bottom: CvSpace.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ReviewEyebrow(
              'Líneas (${lines.length})',
              trailing: ReviewEditButton(
                tooltip: 'Añadir una línea',
                label: 'Añadir línea',
                icon: Icons.add_rounded,
                onPressed: _busy || lines.length >= maxSaleLines ? null : () => _editLine(null),
              ),
            ),
            for (final i in d.issuesFor('lines')) _IssueText(i),
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const Divider(height: 1, thickness: 1, color: CvColors.border),
              _saleLine(d, i, lines[i], canRemove: lines.length > 1),
            ],
            const SizedBox(height: CvSpace.sm),
            SaleTotalBar(
              label: 'Total',
              detail: '${lines.length} ${lines.length == 1 ? 'línea' : 'líneas'}',
              total: total,
              missing: 'Falta algún importe',
              totalKey: const Key('voice-sale-total'),
            ),
          ],
        ),
      ),
      ..._otherIssues(d, const {'client', 'contact', 'sale_date', 'lines', 'notes'}, prefix: 'lines['),
    ];
  }

  Widget _saleLine(ActionDraft d, int i, SaleLineDraft line, {required bool canRemove}) {
    final p = line.product;
    final amountIssues = d.issuesFor('lines[$i].amount');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CvSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: CvColors.primarySoft, shape: BoxShape.circle),
              child: Text('${i + 1}', style: CvText.label.copyWith(fontSize: 12, color: CvColors.primaryDark)),
            ),
          ),
          const SizedBox(width: CvSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                  ReviewRow(
                    label: 'Concepto',
                    dense: true,
                    value: ReviewValue(line.concept),
                    below: [for (final issue in d.issuesFor('lines[$i].product')) _IssueText(issue)],
                  ),
                Wrap(
                  spacing: CvSpace.md,
                  runSpacing: 2,
                  children: [
                    Text('Cantidad: ${line.quantity ?? '—'}', style: CvText.body.copyWith(fontSize: 14)),
                    Text(
                      'Importe: ${line.amountCents != null ? formatEuros(line.amountCents!) : (line.amountSaid ?? '—')}',
                      style: CvText.label.copyWith(fontSize: 14),
                    ),
                  ],
                ),
                if (line.referenceTotalCents != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('PVP de catálogo: ${formatEuros(line.referenceTotalCents!)} (solo orientativo)',
                        style: CvText.helper.copyWith(fontSize: 12.5)),
                  ),
                for (final issue in amountIssues) _IssueText(issue),
              ],
            ),
          ),
          ReviewIconButton(
            tooltip: 'Editar línea ${i + 1}',
            icon: Icons.edit_outlined,
            onPressed: _busy ? null : () => _editLine(i),
          ),
          ReviewIconButton(
            tooltip: 'Quitar línea ${i + 1}',
            icon: Icons.delete_outline_rounded,
            onPressed: _busy || !canRemove ? null : () => _removeLine(i),
          ),
        ],
      ),
    );
  }

  // ---------- I.8: catálogo de productos (nombre y PVP; sin stock) ----------

  String _priceText(ActionDraft d) {
    final cents = d.number('price_cents');
    return cents != null ? formatEuros(cents) : (d.text('price_said') ?? '—');
  }

  /// PVP: se edita como texto y lo interpreta el servidor (mismas reglas que los importes).
  Future<void> _editPrice(ActionDraft d) async {
    final cents = d.number('price_cents');
    final value = await _askText('PVP', cents != null ? centsToInput(cents) : d.text('price_said'), maxLength: 20);
    if (value == null || !mounted || value.trim().isEmpty) return;
    await _patch({'price': value.trim()});
  }

  List<Widget> _productFields(ActionDraft d) {
    return [
      _ValueRow(
        label: 'Nombre',
        value: d.text('name') ?? '—',
        issues: d.issuesFor('name'),
        enabled: !_busy,
        onEdit: () => _editText('name', 'Nombre', maxLength: 100),
      ),
      _ValueRow(
        label: 'PVP',
        value: _priceText(d),
        issues: d.issuesFor('price'),
        enabled: !_busy,
        onEdit: () => _editPrice(d),
      ),
      ..._otherIssues(d, const {'name', 'price'}),
    ];
  }

  /// Cambio de producto: el producto (resuelto por el servidor) y SOLO lo que
  /// cambia, como «antes → después»; lo que no cambia se indica como tal.
  List<Widget> _productUpdateFields(ActionDraft d) {
    final currentName = d.text('current_name');
    final currentPrice = d.number('current_price_cents');
    final newName = d.text('name');
    final priceChanges = d.number('price_cents') != null || d.text('price_said') != null;
    String change(String? before, String? after) =>
        after == null ? 'Sin cambios${before != null ? ' ($before)' : ''}' : '${before ?? '—'} → $after';
    void pick(CatalogItem c) => _patch({'product_id': c.id});
    return [
      _RefRow(
        label: 'Producto',
        ref: d.ref('product'),
        issues: d.issuesFor('product'),
        enabled: !_busy,
        onCandidate: pick,
        onSearch: () => _search('Producto', _api.productItems, pick),
      ),
      _ValueRow(
        label: 'PVP',
        value: change(currentPrice != null ? formatEuros(currentPrice) : null, priceChanges ? _priceText(d) : null),
        strong: priceChanges,
        issues: d.issuesFor('price'),
        enabled: !_busy,
        onEdit: () => _editPrice(d),
      ),
      _ValueRow(
        label: 'Nombre',
        value: change(currentName, newName),
        strong: newName != null,
        issues: d.issuesFor('name'),
        enabled: !_busy,
        onEdit: () => _editText('name', 'Nombre', maxLength: 100),
      ),
      ..._otherIssues(d, const {'product', 'price', 'name'}),
    ];
  }

  /// Issues que no corresponden a ningún campo mostrado (p. ej. duplicados).
  List<Widget> _otherIssues(ActionDraft d, Set<String> shown, {String? prefix}) {
    final rest = d.issues
        .where((i) => !shown.contains(i.field) && !RegExp(r'^products\[\d+\]$').hasMatch(i.field))
        .where((i) => prefix == null || !i.field.startsWith(prefix))
        .toList();
    if (rest.isEmpty) return const [];
    return [
      ReviewRow(
        label: 'Otros avisos',
        value: const SizedBox.shrink(),
        below: [for (final i in rest) _IssueText(i)],
      ),
    ];
  }
}

// =====================================================================
// Piezas de la revisión (datos del borrador → piezas de review_parts.dart)
// =====================================================================

class _IssueText extends StatelessWidget {
  final ApiIssue issue;

  const _IssueText(this.issue);

  @override
  Widget build(BuildContext context) => ReviewIssueText(message: issue.message, blocking: issue.blocking);
}

class _ValueRow extends StatelessWidget {
  final String label;
  final String value;
  final List<ApiIssue> issues;
  final bool enabled;
  final VoidCallback onEdit;
  final IconData editIcon;
  final bool strong;

  const _ValueRow({
    required this.label,
    required this.value,
    required this.issues,
    required this.enabled,
    required this.onEdit,
    this.editIcon = Icons.edit_outlined,
    this.strong = true,
  });

  @override
  Widget build(BuildContext context) {
    return ReviewRow(
      label: label,
      value: ReviewValue(value, strong: strong),
      actions: [
        ReviewEditButton(
          tooltip: 'Cambiar ${label.toLowerCase()}',
          icon: editIcon,
          onPressed: enabled ? onEdit : null,
        ),
      ],
      below: [for (final i in issues) _IssueText(i)],
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

  /// Insignia del estado de la coincidencia (misma lógica que antes; solo
  /// cambia la presentación).
  static (String, ResolutionKind)? badge(ResolvedRef r) {
    switch (r.problem) {
      case 'ambiguous':
        return ('Varias coincidencias', ResolutionKind.ambiguous);
      case 'not_found':
        return ('No encontrado', ResolutionKind.missing);
      case 'conflict':
        return ('No encaja', ResolutionKind.missing);
    }
    if (r.id == null) return ('Sin resolver', ResolutionKind.missing);
    return switch (r.match) {
      'exact' => ('Coincidencia exacta', ResolutionKind.confirmed),
      'fuzzy' || 'partial' => ('Coincidencia aproximada', ResolutionKind.approximate),
      'inherited' => ('Deducido del contacto', ResolutionKind.derived),
      'user_selected' => ('Elegido por ti', ResolutionKind.confirmed),
      'new' => ('Nuevo', ResolutionKind.created),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final r = ref;
    final b = r == null ? null : badge(r);
    final showCandidates = r != null && r.candidates.isNotEmpty && !r.resolved && onCandidate != null;
    return ReviewRow(
      label: label,
      dense: dense,
      value: r == null
          ? const ReviewValue(null)
          : ReviewValue(r.resolved ? r.display : '«${r.display}»', strong: r.resolved, quoted: !r.resolved),
      actions: [
        if (onSearch != null)
          ReviewIconButton(
            tooltip: 'Buscar ${label.toLowerCase()} en el CRM',
            icon: Icons.search_rounded,
            onPressed: enabled ? onSearch : null,
          ),
        if (onClear != null)
          ReviewIconButton(
            tooltip: 'Quitar ${label.toLowerCase()}',
            icon: Icons.close_rounded,
            onPressed: enabled ? onClear : null,
          ),
      ],
      below: [
        if (b != null || (r != null && r.resolved && r.saidDiffers))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: CvSpace.xs,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (b != null) ResolutionBadge(label: b.$1, kind: b.$2),
                if (r != null && r.resolved && r.saidDiffers)
                  Text('Dijiste «${r.said}»', style: CvText.helper.copyWith(fontSize: 12.5)),
              ],
            ),
          ),
        if (showCandidates)
          CandidateOptions(
            labels: [for (final c in r.candidates) c.name],
            onSelected: enabled ? (i) => onCandidate!(r.candidates[i]) : null,
          ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(note!, style: CvText.helper.copyWith(fontSize: 12.5)),
          ),
        for (final i in issues) _IssueText(i),
      ],
    );
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
    return CrmFormShell(
      title: widget.label,
      maxWidth: 480,
      actions: [
        FormCancelButton(onPressed: () => Navigator.pop(context)),
        CvPrimaryButton(label: 'Aplicar', onPressed: () => Navigator.pop(context, _controller.text)),
      ],
      body: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        minLines: widget.multiline ? 3 : 1,
        maxLines: widget.multiline ? 6 : 1,
        decoration: InputDecoration(labelText: widget.label, alignLabelWithHint: widget.multiline),
        onSubmitted: widget.multiline ? null : (v) => Navigator.pop(context, v),
      ),
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
    return CrmFormShell(
      title: widget.line == null ? 'Nueva línea' : 'Editar línea',
      maxWidth: 520,
      actions: [
        FormCancelButton(onPressed: () => Navigator.pop(context)),
        CvPrimaryButton(label: 'Aplicar', onPressed: _apply),
      ],
      body: Form(
        key: _formKey,
        child: FormSection(
          children: [
            if (_product != null)
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Producto',
                  prefixIcon: const Icon(Icons.inventory_2_outlined),
                  suffixIcon: IconButton(
                    tooltip: 'Quitar producto (usar concepto)',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() => _product = null),
                  ),
                ),
                child: Text(_product!.name, style: const TextStyle(fontSize: 15, color: CvColors.textPrimary)),
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
                    icon: const Icon(Icons.search_rounded),
                    onPressed: _pickProduct,
                  ),
                ),
                validator: (v) => (v?.trim().isEmpty ?? true) ? 'Indica un producto o un concepto' : null,
              ),
            FieldPair(
              minWidth: 400,
              firstFlex: 2,
              secondFlex: 3,
              first: TextFormField(
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
              second: TextFormField(
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
            ),
          ],
        ),
      ),
    );
  }
}
