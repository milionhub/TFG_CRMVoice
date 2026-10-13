// Modelos tipados del CRM (H.3) para los contratos REST de H.2.
//
// Todos los fromJson son defensivos: los datos heredados pueden traer
// campos a null y el listado de actividades usa todavía los nombres
// anteriores ("fecha", "cliente", "accion"...), por eso CrmActivity acepta
// las dos formas.

int? _int(Object? value) => value is int ? value : (value is num ? value.toInt() : null);

String? _str(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
    : const [];

/// Elemento de catálogo (cliente, contacto, tipo de actividad, producto).
class CatalogItem {
  final int id;
  final String name;

  const CatalogItem(this.id, this.name);

  static CatalogItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _int(json['id']);
    if (id == null) return null;
    return CatalogItem(id, _str(json['name']) ?? '#$id');
  }

  static List<CatalogItem> listFrom(Object? json) =>
      json is List ? json.map(fromJson).whereType<CatalogItem>().toList() : const [];
}

// =====================================================================
// Clientes y contactos
// =====================================================================

/// Fila del listado GET /clients (hoy solo id y name; el resto, si llega).
class ClientSummary {
  final int id;
  final String name;
  final String? alias;
  final String? city;
  final String? province;

  const ClientSummary({required this.id, required this.name, this.alias, this.city, this.province});

  static ClientSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _int(json['id']);
    if (id == null) return null;
    return ClientSummary(
      id: id,
      name: _str(json['name']) ?? 'Cliente #$id',
      alias: _str(json['alias']),
      city: _str(json['city']),
      province: _str(json['province']),
    );
  }
}

class Client {
  final int id;
  final String name;
  final String? alias;
  final String? city;
  final String? province;
  final int? groupId;
  final String? groupName;
  final String? phone;
  final String? email;
  final String? cif;

  const Client({
    required this.id,
    required this.name,
    this.alias,
    this.city,
    this.province,
    this.groupId,
    this.groupName,
    this.phone,
    this.email,
    this.cif,
  });

  factory Client.fromJson(Map<String, dynamic> json) => Client(
        id: _int(json['id']) ?? 0,
        name: _str(json['name']) ?? '',
        alias: _str(json['alias']),
        city: _str(json['city']),
        province: _str(json['province']),
        groupId: _int(json['group_id']),
        groupName: _str(json['group_name']),
        phone: _str(json['phone']),
        email: _str(json['email']),
        cif: _str(json['cif']),
      );

  /// "Población (Provincia)" o lo que haya.
  String? get location {
    if (city != null && province != null && city != province) return '$city ($province)';
    return city ?? province;
  }
}

/// Cuerpo de POST/PUT /clients (ClientIn). PUT sustituye todos los campos.
class ClientInput {
  final String name;
  final String? alias;
  final String? city;
  final String? province;
  final int? groupId;
  final String? phone;
  final String? email;
  final String? cif;

  const ClientInput({
    required this.name,
    this.alias,
    this.city,
    this.province,
    this.groupId,
    this.phone,
    this.email,
    this.cif,
  });

  Map<String, dynamic> toJson() => {
        'name': name.trim(),
        'alias': _str(alias),
        'city': _str(city),
        'province': _str(province),
        'group_id': groupId,
        'phone': _str(phone),
        'email': _str(email),
        'cif': _str(cif),
      };
}

/// Aviso no bloqueante del backend (p. ej. "similar" al crear un cliente).
class ApiIssue {
  final String code;
  final String field;
  final String message;
  final bool blocking;
  final int? existingId;
  final List<CatalogItem> candidates;

  const ApiIssue({
    required this.code,
    required this.field,
    required this.message,
    this.blocking = true,
    this.existingId,
    this.candidates = const [],
  });

  static ApiIssue? fromJson(Object? json) {
    if (json is! Map) return null;
    final message = _str(json['message']);
    if (message == null) return null;
    return ApiIssue(
      code: _str(json['code']) ?? 'invalid',
      field: _str(json['field']) ?? '',
      message: message,
      blocking: json['blocking'] != false,
      existingId: _int(json['existing_id']),
      candidates: (json['candidates'] is List ? json['candidates'] as List : const [])
          .whereType<Map>()
          .map((c) => _int(c['id']) == null ? null : CatalogItem(_int(c['id'])!, _str(c['label']) ?? ''))
          .whereType<CatalogItem>()
          .toList(),
    );
  }

  static List<ApiIssue> listFrom(Object? json) =>
      json is List ? json.map(fromJson).whereType<ApiIssue>().toList() : const [];
}

class ClientSaveResult {
  final Client client;
  final List<ApiIssue> warnings;

  const ClientSaveResult(this.client, this.warnings);

  factory ClientSaveResult.fromJson(Map<String, dynamic> json) =>
      ClientSaveResult(Client.fromJson(json), ApiIssue.listFrom(json['warnings']));
}

class Contact {
  final int id;
  final String name;
  final String? role;
  final String? email;
  final String? phone;

  const Contact({required this.id, required this.name, this.role, this.email, this.phone});

  static Contact? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _int(json['id']);
    if (id == null) return null;
    return Contact(
      id: id,
      name: _str(json['name']) ?? 'Contacto #$id',
      role: _str(json['role']),
      email: _str(json['email']),
      phone: _str(json['phone']),
    );
  }
}

/// Cuerpo de POST /contacts (con clientId) y PUT /contacts/{id} (sin él).
class ContactInput {
  final String name;
  final String? role;
  final String? email;
  final String? phone;

  const ContactInput({required this.name, this.role, this.email, this.phone});

  Map<String, dynamic> toJson({int? clientId}) => {
        if (clientId != null) 'client_id': clientId,
        'name': name.trim(),
        'role': _str(role),
        'email': _str(email),
        'phone': _str(phone),
      };
}

// =====================================================================
// Actividades V2
// =====================================================================

enum ActivityStatus {
  pending('pending', 'Pendiente'),
  completed('completed', 'Completada'),
  cancelled('cancelled', 'Cancelada');

  final String api;
  final String label;

  const ActivityStatus(this.api, this.label);

  static ActivityStatus? fromApi(Object? value) {
    for (final status in values) {
      if (status.api == value) return status;
    }
    return null;
  }
}

/// "2026-10-01T10:30:00" (hora local, sin zona) -> DateTime local.
DateTime? parseLocalDateTime(Object? value) => value is String ? DateTime.tryParse(value) : null;

/// DateTime -> "YYYY-MM-DDTHH:MM" (el backend lo normaliza a ...:00).
String formatApiDateTime(DateTime d) =>
    '${formatApiDate(d)}T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// DateTime -> "YYYY-MM-DD".
String formatApiDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class CrmActivity {
  final int id;
  final DateTime? datetime;
  final int? clientId;
  final String? clientName;
  final int? contactId;
  final String? contactName;
  final int? activityTypeId;
  final String? activityType;
  final ActivityStatus? status;
  final String? comment;
  final List<CatalogItem> products;

  /// Productos heredados sin producto de catálogo (solo texto): no se pueden
  /// reenviar en una edición V2 (product_ids).
  final List<String> unlinkedProducts;

  const CrmActivity({
    required this.id,
    this.datetime,
    this.clientId,
    this.clientName,
    this.contactId,
    this.contactName,
    this.activityTypeId,
    this.activityType,
    this.status,
    this.comment,
    this.products = const [],
    this.unlinkedProducts = const [],
  });

  /// Acepta la salida V2 (activity_out) y la del listado GET /activities.
  static CrmActivity? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _int(json['id']);
    if (id == null) return null;
    final products = <CatalogItem>[];
    final unlinked = <String>[];
    for (final p in _maps(json['products'])) {
      final productId = _int(p['id'] ?? p['product_id']);
      final name = _str(p['name'] ?? p['product_raw']);
      if (productId != null) {
        products.add(CatalogItem(productId, name ?? 'Producto #$productId'));
      } else if (name != null) {
        unlinked.add(name);
      }
    }
    return CrmActivity(
      id: id,
      datetime: parseLocalDateTime(json['datetime'] ?? json['fecha']),
      clientId: _int(json['client_id']),
      clientName: _str(json['client_name'] ?? json['cliente']),
      contactId: _int(json['contact_id']),
      contactName: _str(json['contact_name'] ?? json['contacto']),
      activityTypeId: _int(json['activity_type_id']),
      activityType: _str(json['activity_type'] ?? json['accion']),
      status: ActivityStatus.fromApi(json['status']),
      comment: _str(json['comment'] ?? json['comentario']),
      products: products,
      unlinkedProducts: unlinked,
    );
  }

  static List<CrmActivity> listFrom(Object? json) =>
      json is List ? json.map(fromJson).whereType<CrmActivity>().toList() : const [];

  bool get isFuture => datetime != null && datetime!.isAfter(DateTime.now());

  /// Pendiente con la fecha ya pasada.
  bool get isOverdue => status == ActivityStatus.pending && datetime != null && !isFuture;

  /// Estados a los que se puede pasar desde la UI (el backend decide al final).
  List<ActivityStatus> get allowedTransitions => ActivityStatus.values
      .where((s) => s != status)
      .where((s) => !(s == ActivityStatus.completed && isFuture))
      .toList();
}

/// Cuerpo de POST/PUT /activities (ActivityIn, V2).
class ActivityInput {
  final int clientId;
  final int? contactId;
  final int activityTypeId;
  final DateTime datetime;
  final ActivityStatus status;
  final List<int> productIds;
  final String? comment;

  const ActivityInput({
    required this.clientId,
    this.contactId,
    required this.activityTypeId,
    required this.datetime,
    required this.status,
    this.productIds = const [],
    this.comment,
  });

  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'contact_id': contactId,
        'activity_type_id': activityTypeId,
        'datetime': formatApiDateTime(datetime),
        'status': status.api,
        'product_ids': productIds,
        'comment': _str(comment),
      };
}

// =====================================================================
// Ventas
// =====================================================================

class Sale {
  final int id;
  final int? clientId;
  final int? contactId;
  final String? contactName;
  final int? productId;
  final String? productName;
  final String? concept;
  final int? quantity;
  final int amountCents;
  final String? saleDate; // "YYYY-MM-DD"
  final String? notes;

  const Sale({
    required this.id,
    this.clientId,
    this.contactId,
    this.contactName,
    this.productId,
    this.productName,
    this.concept,
    this.quantity,
    required this.amountCents,
    this.saleDate,
    this.notes,
  });

  static Sale? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _int(json['id']);
    if (id == null) return null;
    return Sale(
      id: id,
      clientId: _int(json['client_id']),
      contactId: _int(json['contact_id']),
      contactName: _str(json['contact_name']),
      productId: _int(json['product_id']),
      productName: _str(json['product_name']),
      concept: _str(json['concept']),
      quantity: _int(json['quantity']),
      amountCents: _int(json['amount_cents']) ?? 0,
      saleDate: _str(json['sale_date']),
      notes: _str(json['notes']),
    );
  }

  static List<Sale> listFrom(Object? json) =>
      json is List ? json.map(fromJson).whereType<Sale>().toList() : const [];

  String get label => productName ?? concept ?? 'Venta';
}

/// Una línea de venta tal como la escribe el usuario. El importe viaja como
/// TEXTO en euros ("4.500,00"): lo interpreta el backend (nunca un double).
class SaleLineInput {
  final int? productId;
  final String? concept;
  final int? quantity;
  final String amount;

  const SaleLineInput({this.productId, this.concept, this.quantity, required this.amount});

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'concept': productId == null ? _str(concept) : null,
        'quantity': quantity,
        'amount': amount.trim(),
      };
}

/// POST /sales: 1 a 5 líneas que se guardan juntas.
class SaleCreateInput {
  final int clientId;
  final int? contactId;
  final String saleDate;
  final String? notes;
  final List<SaleLineInput> lines;

  const SaleCreateInput({
    required this.clientId,
    this.contactId,
    required this.saleDate,
    this.notes,
    required this.lines,
  });

  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'contact_id': contactId,
        'sale_date': saleDate,
        'notes': _str(notes),
        'lines': lines.map((l) => l.toJson()).toList(),
      };
}

/// PUT /sales/{id}: una venta (una línea), sustitución completa.
class SaleUpdateInput {
  final int clientId;
  final int? contactId;
  final String saleDate;
  final String? notes;
  final SaleLineInput line;

  const SaleUpdateInput({
    required this.clientId,
    this.contactId,
    required this.saleDate,
    this.notes,
    required this.line,
  });

  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'contact_id': contactId,
        'sale_date': saleDate,
        'notes': _str(notes),
        ...line.toJson(),
      };
}

// =====================================================================
// Ficha de cliente (GET /clients/{id})
// =====================================================================

class ClientRevenue {
  final int invoicesCents;
  final int invoiceLines;
  final int mySalesCents;
  final int mySalesLines;
  final int totalCents;

  const ClientRevenue({
    this.invoicesCents = 0,
    this.invoiceLines = 0,
    this.mySalesCents = 0,
    this.mySalesLines = 0,
    this.totalCents = 0,
  });

  factory ClientRevenue.fromJson(Object? json) {
    if (json is! Map) return const ClientRevenue();
    return ClientRevenue(
      invoicesCents: _int(json['invoices_cents']) ?? 0,
      invoiceLines: _int(json['invoice_lines']) ?? 0,
      mySalesCents: _int(json['my_sales_cents']) ?? 0,
      mySalesLines: _int(json['my_sales_lines']) ?? 0,
      totalCents: _int(json['total_cents']) ?? 0,
    );
  }
}

class ClientDetail {
  final Client client;
  final List<Contact> contacts;
  final List<Sale> sales;
  final ClientRevenue revenue;
  final List<String> discussedProducts;

  const ClientDetail({
    required this.client,
    this.contacts = const [],
    this.sales = const [],
    this.revenue = const ClientRevenue(),
    this.discussedProducts = const [],
  });

  factory ClientDetail.fromJson(Map<String, dynamic> json) {
    final client = json['client'];
    if (client is! Map) throw const FormatException('ficha sin cliente');
    return ClientDetail(
      client: Client.fromJson(Map<String, dynamic>.from(client)),
      contacts: (json['contacts'] is List ? json['contacts'] as List : const [])
          .map(Contact.fromJson)
          .whereType<Contact>()
          .toList(),
      sales: Sale.listFrom(json['sales']),
      revenue: ClientRevenue.fromJson(json['revenue']),
      discussedProducts: _maps(json['discussed_products'])
          .map((p) => _str(p['name'] ?? p['product']))
          .whereType<String>()
          .toList(),
    );
  }
}

// =====================================================================
// Métricas de Home (GET /dashboard, H.5.2)
// =====================================================================

class DashboardData {
  final int pending;
  final int overdue;
  final int upcoming;
  final int upcoming7d;
  final List<CrmActivity> nextActivities;
  final String? salesMonth; // "YYYY-MM"
  final int salesMonthCents;
  final int salesMonthLines;

  const DashboardData({
    this.pending = 0,
    this.overdue = 0,
    this.upcoming = 0,
    this.upcoming7d = 0,
    this.nextActivities = const [],
    this.salesMonth,
    this.salesMonthCents = 0,
    this.salesMonthLines = 0,
  });

  factory DashboardData.fromJson(Map<String, dynamic> json) {
    final a = json['activities'] is Map ? Map<String, dynamic>.from(json['activities']) : const <String, dynamic>{};
    final s = json['sales_month'] is Map ? Map<String, dynamic>.from(json['sales_month']) : const <String, dynamic>{};
    return DashboardData(
      pending: _int(a['pending']) ?? 0,
      overdue: _int(a['overdue']) ?? 0,
      upcoming: _int(a['upcoming']) ?? 0,
      upcoming7d: _int(a['upcoming_7d']) ?? 0,
      nextActivities: CrmActivity.listFrom(json['next_activities']),
      salesMonth: _str(s['month']),
      salesMonthCents: _int(s['total_cents']) ?? 0,
      salesMonthLines: _int(s['line_count']) ?? 0,
    );
  }

  bool get isEmpty => pending == 0 && upcoming == 0 && salesMonthLines == 0 && nextActivities.isEmpty;
}
