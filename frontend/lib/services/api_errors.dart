// Errores de la API del CRM (H.3): una sola traducción de las respuestas de
// error de H.2 ({"detail", "issues", "code", "existing_id"}) a mensajes
// cortos en español. Nunca se muestra al usuario un volcado de FastAPI.
import 'dart:convert';

import '../models/crm.dart';

enum ApiErrorKind { network, unauthorized, notFound, validation, duplicate, conflict, server }

class ApiException implements Exception {
  final ApiErrorKind kind;
  final int? statusCode;
  final String message;
  final List<ApiIssue> issues;
  final int? existingId;

  const ApiException(
    this.kind,
    this.message, {
    this.statusCode,
    this.issues = const [],
    this.existingId,
  });

  const ApiException.network()
      : this(ApiErrorKind.network, 'No se pudo conectar con el servidor. Revisa la conexión e inténtalo de nuevo.');

  /// Construye el error a partir de una respuesta HTTP no satisfactoria.
  factory ApiException.fromResponse(int status, List<int> bodyBytes) {
    Object? body;
    try {
      body = jsonDecode(utf8.decode(bodyBytes));
    } catch (_) {
      body = null;
    }
    final map = body is Map ? body : const {};
    final issues = ApiIssue.listFrom(map['issues']);
    final detail = map['detail'] is String ? (map['detail'] as String).trim() : null;
    final existingId = map['existing_id'] is int ? map['existing_id'] as int : null;

    switch (status) {
      case 401:
      case 403:
        return ApiException(ApiErrorKind.unauthorized, 'Tu sesión ha caducado. Vuelve a iniciar sesión.',
            statusCode: status);
      case 404:
        return ApiException(ApiErrorKind.notFound, detail ?? 'No se ha encontrado el registro.',
            statusCode: status);
      case 409:
        final duplicate = map['code'] is String && (map['code'] as String).startsWith('duplicate') ||
            issues.any((i) => i.code == 'duplicate');
        return ApiException(
          duplicate ? ApiErrorKind.duplicate : ApiErrorKind.conflict,
          detail ?? (issues.isNotEmpty ? issues.first.message : 'Conflicto con datos existentes.'),
          statusCode: status,
          issues: issues,
          existingId: existingId ?? (issues.isNotEmpty ? issues.first.existingId : null),
        );
      case 400:
      case 422:
        // Los 422 de forma de FastAPI traen "detail" como lista: se usan los issues
        final message = issues.isNotEmpty
            ? (issues.length == 1 ? describeIssue(issues.first) : 'Revisa los datos marcados.')
            : (detail ?? 'Datos no válidos.');
        return ApiException(ApiErrorKind.validation, message, statusCode: status, issues: issues);
      default:
        return ApiException(ApiErrorKind.server, 'Error del servidor ($status). Inténtalo de nuevo más tarde.',
            statusCode: status);
    }
  }

  /// Mensaje del issue de ese campo exacto ("name", "lines[0].amount"...).
  String? messageFor(String field) {
    for (final issue in issues) {
      if (issue.field == field) return issue.message;
    }
    return null;
  }

  /// Mensajes de todos los issues, con el campo en lenguaje natural.
  List<String> get issueMessages => issues.map(describeIssue).toList();

  @override
  String toString() => 'ApiException(${kind.name}, $statusCode, $message)';
}

const _fieldLabels = {
  'name': 'Nombre',
  'alias': 'Alias',
  'city': 'Población',
  'province': 'Provincia',
  'phone': 'Teléfono',
  'email': 'Email',
  'cif': 'CIF',
  'group': 'Grupo',
  'group_id': 'Grupo',
  'role': 'Cargo',
  'client': 'Cliente',
  'client_id': 'Cliente',
  'contact': 'Contacto',
  'contact_id': 'Contacto',
  'activity_type': 'Tipo de actividad',
  'activity_type_id': 'Tipo de actividad',
  'datetime': 'Fecha y hora',
  'status': 'Estado',
  'comment': 'Comentario',
  'products': 'Productos',
  'product_ids': 'Productos',
  'sale_date': 'Fecha de venta',
  'notes': 'Notas',
  'lines': 'Líneas',
  'product': 'Producto',
  'product_id': 'Producto',
  'concept': 'Concepto',
  'quantity': 'Cantidad',
  'amount': 'Importe',
  'activity': 'Actividad',
};

/// "lines[1].amount" -> "Línea 2 · Importe"; "products[0]" -> "Productos".
String fieldLabel(String field) {
  final parts = <String>[];
  for (final part in field.split('.')) {
    final match = RegExp(r'^(\w+)\[(\d+)\]$').firstMatch(part);
    if (match != null && match.group(1) == 'lines') {
      parts.add('Línea ${int.parse(match.group(2)!) + 1}');
    } else {
      final key = match?.group(1) ?? part;
      parts.add(_fieldLabels[key] ?? key);
    }
  }
  return parts.join(' · ');
}

String describeIssue(ApiIssue issue) {
  if (issue.field.isEmpty || issue.field == 'body') return issue.message;
  return '${fieldLabel(issue.field)}: ${issue.message}';
}

/// Mensaje para cualquier error capturado en una pantalla.
String userMessage(Object error) =>
    error is ApiException ? error.message : 'Ha ocurrido un error inesperado. Inténtalo de nuevo.';
