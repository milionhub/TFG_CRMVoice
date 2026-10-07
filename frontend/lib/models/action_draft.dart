// Borradores del Action Engine (H.2) tal como los devuelve la API
// (DraftView). Voice V2 (H.4) los muestra y edita; el servidor es quien
// resuelve las entidades (ids, candidatos, problemas) y decide si se puede
// confirmar. Aquí no se resuelve ni se inventa nada.
import 'crm.dart';

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

String? _str(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

enum ActionType {
  createActivity('create_activity', 'Nueva actividad'),
  createClient('create_client', 'Nuevo cliente'),
  createContact('create_contact', 'Nuevo contacto'),
  createSale('create_sale', 'Nueva venta'),
  // I.8: catálogo de productos (nombre y PVP; sin stock)
  createProduct('create_product', 'Nuevo producto'),
  updateProduct('update_product', 'Cambio de producto');

  final String api;
  final String label;

  const ActionType(this.api, this.label);

  static ActionType? fromApi(Object? v) {
    for (final t in values) {
      if (t.api == v) return t;
    }
    return null;
  }
}

/// Entidad del CRM tal como la resolvió el servidor.
class ResolvedRef {
  final int? id;
  final String? label; // nombre oficial
  final String? said; // lo que se dijo
  final String? match; // exact | fuzzy | partial | inherited | user_selected | new
  final String? problem; // ambiguous | not_found | conflict
  final List<CatalogItem> candidates;

  const ResolvedRef({this.id, this.label, this.said, this.match, this.problem, this.candidates = const []});

  static ResolvedRef? fromJson(Object? json) {
    if (json is! Map) return null;
    return ResolvedRef(
      id: _int(json['id']),
      label: _str(json['label']),
      said: _str(json['said']),
      match: _str(json['match']),
      problem: _str(json['problem']),
      candidates: (json['candidates'] is List ? json['candidates'] as List : const [])
          .whereType<Map>()
          .map((c) => _int(c['id']) == null ? null : CatalogItem(_int(c['id'])!, _str(c['label']) ?? '#${c['id']}'))
          .whereType<CatalogItem>()
          .toList(),
    );
  }

  bool get resolved => id != null && problem == null;

  /// Texto principal: el nombre oficial o, si no se resolvió, lo dicho.
  String get display => label ?? said ?? '—';

  /// Lo dicho difiere del nombre oficial (sin tildes ni mayúsculas).
  bool get saidDiffers => said != null && label != null && foldText(said!) != foldText(label!);
}

String foldText(String s) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñç';
  const to = 'aaaaeeeeiiiioooouuuunc';
  final buffer = StringBuffer();
  for (final ch in s.toLowerCase().trim().split('')) {
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i] : ch);
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ');
}

class SaleLineDraft {
  final ResolvedRef? product;
  final String? concept;
  final int? quantity;
  final int? amountCents;
  final String? amountSaid;
  final String? amountError;
  final int? referenceTotalCents;

  const SaleLineDraft({
    this.product,
    this.concept,
    this.quantity,
    this.amountCents,
    this.amountSaid,
    this.amountError,
    this.referenceTotalCents,
  });

  factory SaleLineDraft.fromJson(Map<String, dynamic> j) => SaleLineDraft(
        product: ResolvedRef.fromJson(j['product']),
        concept: _str(j['concept']),
        quantity: _int(j['quantity']),
        amountCents: _int(j['amount_cents']),
        amountSaid: _str(j['amount_said']),
        amountError: _str(j['amount_error']),
        referenceTotalCents: _int(j['reference_total_cents']),
      );
}

/// Resultado de un borrador confirmado ({"entity", "ids", "data"}).
class ActionResult {
  final String entity; // activity | client | contact | sale
  final List<int> ids;
  final Object? data;

  const ActionResult({required this.entity, this.ids = const [], this.data});

  static ActionResult? fromJson(Object? json) {
    if (json is! Map) return null;
    final entity = _str(json['entity']);
    if (entity == null) return null;
    return ActionResult(
      entity: entity,
      ids: (json['ids'] is List ? json['ids'] as List : const []).map(_int).whereType<int>().toList(),
      data: json['data'],
    );
  }

  /// Cliente afectado (para abrir su ficha), si se sabe.
  int? get clientId {
    final d = data;
    if (entity == 'client') return ids.isEmpty ? null : ids.first;
    if (d is Map) return _int(d['client_id']);
    if (d is List && d.isNotEmpty && d.first is Map) return _int((d.first as Map)['client_id']);
    return null;
  }

  String? get clientName {
    final d = data;
    if (d is Map) return _str(entity == 'client' ? d['name'] : d['client_name']);
    if (d is List && d.isNotEmpty && d.first is Map) return _str((d.first as Map)['client_name']);
    return null;
  }
}

class ActionDraft {
  final String id;
  final ActionType type;
  final String status; // open | executed | cancelled
  final int revision;
  final String sourceText;
  final Map<String, dynamic> fields;
  final List<ApiIssue> issues;
  final bool confirmable;
  final bool expired;
  final String? expiresAt;
  final ActionResult? result;

  const ActionDraft({
    required this.id,
    required this.type,
    required this.status,
    required this.revision,
    required this.sourceText,
    required this.fields,
    this.issues = const [],
    this.confirmable = false,
    this.expired = false,
    this.expiresAt,
    this.result,
  });

  /// null si no es un DraftView reconocible (acción desconocida incluida).
  static ActionDraft? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = _str(json['id']);
    final type = ActionType.fromApi(json['action_type']);
    final revision = _int(json['revision']);
    if (id == null || type == null || revision == null) return null;
    return ActionDraft(
      id: id,
      type: type,
      status: _str(json['status']) ?? 'open',
      revision: revision,
      sourceText: json['source_text'] is String ? json['source_text'] as String : '',
      fields: _map(json['fields']),
      issues: ApiIssue.listFrom(json['issues']),
      confirmable: json['confirmable'] == true,
      expired: json['expired'] == true,
      expiresAt: _str(json['expires_at']),
      result: ActionResult.fromJson(json['result']),
    );
  }

  bool get isOpen => status == 'open' && !expired;
  bool get isExecuted => status == 'executed';

  List<ApiIssue> get blockingIssues => issues.where((i) => i.blocking).toList();
  List<ApiIssue> get warnings => issues.where((i) => !i.blocking).toList();

  List<ApiIssue> issuesFor(String field) => issues.where((i) => i.field == field).toList();

  ResolvedRef? ref(String key) => ResolvedRef.fromJson(fields[key]);
  String? text(String key) => _str(fields[key]);
  int? number(String key) => _int(fields[key]);

  List<ResolvedRef> get products =>
      (fields['products'] is List ? fields['products'] as List : const []).map(ResolvedRef.fromJson).whereType<ResolvedRef>().toList();

  List<SaleLineDraft> get lines => (fields['lines'] is List ? fields['lines'] as List : const [])
      .whereType<Map>()
      .map((l) => SaleLineDraft.fromJson(Map<String, dynamic>.from(l)))
      .toList();

  /// Total de la venta en céntimos, o null si falta algún importe.
  int? get saleTotalCents {
    final ls = lines;
    if (ls.isEmpty || ls.any((l) => l.amountCents == null)) return null;
    return ls.fold<int>(0, (sum, l) => sum + l.amountCents!);
  }
}

/// Respuesta de POST /actions/interpret-audio.
class VoiceInterpretation {
  final String transcript;
  final ActionDraft draft;

  const VoiceInterpretation(this.transcript, this.draft);
}

/// Respuesta de POST /actions/{id}/confirm.
class ConfirmOutcome {
  final ActionResult? result;
  final ActionDraft? draft;

  const ConfirmOutcome(this.result, this.draft);
}
