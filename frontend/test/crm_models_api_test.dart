// H.3: importes sin coma flotante, modelos tipados (incluidas las dos formas
// de actividad), serialización de los cuerpos H.2 y traducción de errores.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/money.dart';
import 'package:frontend/models/crm.dart';
import 'package:frontend/services/api_service.dart';
import 'package:http/http.dart' as http;

import 'support/test_support.dart';

void main() {
  group('importes (mismo criterio que core/formats.py)', () {
    test('acepta los formatos españoles habituales y devuelve céntimos enteros', () {
      expect(parseEuroCents('4500'), 450000);
      expect(parseEuroCents('4500,00'), 450000);
      expect(parseEuroCents('4500.5'), 450050);
      expect(parseEuroCents('4.500'), 450000);
      expect(parseEuroCents('4.500,25'), 450025);
      expect(parseEuroCents('1.234.567,89'), 123456789);
      expect(parseEuroCents(' 12,30 € '), 1230);
    });

    test('rechaza lo ambiguo, más de dos decimales, cero y texto', () {
      for (final bad in ['4,500', '4500,123', '0', '0,00', '-5', 'abc', '', '4.50.0']) {
        expect(parseEuroCents(bad), isNull, reason: bad);
        expect(validateEuroAmount(bad), isNotNull, reason: bad);
      }
      expect(validateEuroAmount('4,500'), contains('ambiguo'));
      expect(validateEuroAmount('4500,00'), isNull);
    });

    test('formato EUR y texto editable sin separador de miles', () {
      expect(formatEuros(450000), '4.500,00 €');
      expect(formatEuros(123456789), '1.234.567,89 €');
      expect(formatEuros(5), '0,05 €');
      expect(centsToInput(450000), '4500');
      expect(centsToInput(450050), '4500,50');
      // Ida y vuelta exacta
      expect(parseEuroCents(centsToInput(123456789)), 123456789);
    });
  });

  group('modelos', () {
    test('CrmActivity acepta el listado (fecha/cliente/accion) y la salida V2', () {
      final legacy = CrmActivity.fromJson({
        "id": 1,
        "fecha": "2026-10-01T10:30:00",
        "client_id": 3,
        "cliente": "Nebula",
        "contact_id": null,
        "activity_type_id": 2,
        "accion": "Concertar reunión",
        "comentario": "Hola",
        "status": "pending",
        "products": [
          {"product_id": 4, "product_raw": "Monitor"},
          {"product_id": null, "product_raw": "Algo heredado"},
        ],
      })!;
      expect(legacy.datetime, DateTime(2026, 10, 1, 10, 30));
      expect(legacy.clientName, 'Nebula');
      expect(legacy.activityType, 'Concertar reunión');
      expect(legacy.status, ActivityStatus.pending);
      expect(legacy.products.single.id, 4);
      expect(legacy.unlinkedProducts, ['Algo heredado']);

      final v2 = CrmActivity.fromJson({
        "id": 2,
        "datetime": "2026-10-01T10:30:00",
        "client_id": 3,
        "client_name": "Nebula",
        "activity_type": "Llamada",
        "status": "completed",
        "comment": null,
        "products": [
          {"id": 4, "name": "Monitor"}
        ],
      })!;
      expect(v2.clientName, 'Nebula');
      expect(v2.status, ActivityStatus.completed);
      expect(v2.products.single.name, 'Monitor');

      // Datos heredados incompletos: sin excepción
      final bare = CrmActivity.fromJson({"id": 9, "status": "raro"})!;
      expect(bare.status, isNull);
      expect(bare.datetime, isNull);
      expect(CrmActivity.fromJson({"sin": "id"}), isNull);
    });

    test('transiciones de estado: una futura no se puede completar', () {
      final future = CrmActivity(
          id: 1, datetime: DateTime.now().add(const Duration(days: 2)), status: ActivityStatus.pending);
      expect(future.allowedTransitions, [ActivityStatus.cancelled]);
      final past = CrmActivity(
          id: 1, datetime: DateTime.now().subtract(const Duration(days: 2)), status: ActivityStatus.pending);
      expect(past.isOverdue, isTrue);
      expect(past.allowedTransitions, [ActivityStatus.completed, ActivityStatus.cancelled]);
    });

    test('ClientDetail: ingresos separados por origen y datos opcionales a null', () {
      final detail = ClientDetail.fromJson({
        "client": {"id": 1, "name": "Nebula", "alias": null, "city": "Madrid", "province": "Madrid"},
        "contacts": [
          {"id": 2, "name": "Nora", "role": null, "email": null, "phone": null}
        ],
        "recent_activities": [],
        "sales": [
          {"id": 5, "amount_cents": 1999, "sale_date": "2026-09-01", "product_name": null, "concept": "Instalación"}
        ],
        "revenue": {
          "invoices_cents": 100000,
          "invoice_lines": 3,
          "my_sales_cents": 1999,
          "my_sales_lines": 1,
          "total_cents": 101999
        },
        "discussed_products": [
          {"id": 4, "name": "Monitor"}
        ],
      });
      expect(detail.client.location, 'Madrid');
      expect(detail.contacts.single.role, isNull);
      expect(detail.sales.single.label, 'Instalación');
      expect(detail.revenue.invoicesCents, 100000);
      expect(detail.revenue.mySalesCents, 1999);
      expect(detail.discussedProducts, ['Monitor']);
    });
  });

  group('serialización de los cuerpos H.2', () {
    test('ActivityInput: V2 con fecha local "YYYY-MM-DDTHH:MM" y comentario vacío a null', () {
      final body = ActivityInput(
        clientId: 1,
        contactId: null,
        activityTypeId: 2,
        datetime: DateTime(2026, 3, 4, 9, 5),
        status: ActivityStatus.pending,
        productIds: [4],
        comment: '   ',
      ).toJson();
      expect(body, {
        "client_id": 1,
        "contact_id": null,
        "activity_type_id": 2,
        "datetime": "2026-03-04T09:05",
        "status": "pending",
        "product_ids": [4],
        "comment": null,
      });
    });

    test('SaleCreateInput: el importe viaja como texto y producto excluye concepto', () {
      final body = const SaleCreateInput(
        clientId: 1,
        saleDate: '2026-09-30',
        notes: '',
        lines: [
          SaleLineInput(productId: 4, concept: 'ignorado', quantity: 2, amount: '4.500,00'),
          SaleLineInput(concept: 'Instalación', amount: ' 120 '),
        ],
      ).toJson();
      expect(body["notes"], isNull);
      expect(body["lines"], [
        {"product_id": 4, "concept": null, "quantity": 2, "amount": "4.500,00"},
        {"product_id": null, "concept": "Instalación", "quantity": null, "amount": "120"},
      ]);
    });

    test('ContactInput: client_id solo en el alta', () {
      const input = ContactInput(name: ' Nora ', role: '', email: 'n@x.es');
      expect(input.toJson(clientId: 3), {"client_id": 3, "name": "Nora", "role": null, "email": "n@x.es", "phone": null});
      expect(input.toJson().containsKey('client_id'), isFalse);
    });
  });

  group('errores de la API', () {
    List<int> body(Object json) => utf8.encode(jsonEncode(json));

    test('409 duplicado conserva el registro existente y el mensaje del dominio', () {
      final e = ApiException.fromResponse(409, body({
        "detail": "Ya existe el cliente «Nebula».",
        "code": "duplicate_client",
        "existing_id": 7,
        "issues": [
          {"code": "duplicate", "field": "client", "message": "Ya existe el cliente «Nebula».", "blocking": true}
        ],
      }));
      expect(e.kind, ApiErrorKind.duplicate);
      expect(e.existingId, 7);
      expect(e.message, 'Ya existe el cliente «Nebula».');
    });

    test('422 de FastAPI (detail lista): usa los issues en español, nunca el volcado', () {
      final e = ApiException.fromResponse(422, body({
        "detail": [
          {"type": "value_error", "loc": ["body", "lines", 1, "amount"], "msg": "Value error, Importe no válido"}
        ],
        "issues": [
          {"code": "invalid", "field": "lines[1].amount", "message": "Importe no válido.", "blocking": true}
        ],
      }));
      expect(e.kind, ApiErrorKind.validation);
      expect(e.message, 'Línea 2 · Importe: Importe no válido.');
      expect(e.messageFor('lines[1].amount'), 'Importe no válido.');
      expect(e.message, isNot(contains('value_error')));
    });

    test('500 sin JSON y 401 dan mensajes genéricos', () {
      expect(ApiException.fromResponse(500, utf8.encode('Internal Server Error')).message,
          contains('Error del servidor'));
      expect(ApiException.fromResponse(401, body({"detail": "x"})).kind, ApiErrorKind.unauthorized);
    });
  });

  group('ApiService CRM', () {
    late FakeBackend backend;

    setUp(() {
      cleanPreferences();
      backend = FakeBackend();
    });

    tearDown(() => backend.expectNoUnexpectedRequests());

    Future<ApiService> api() async => ApiService(await loggedInAuth(backend));

    test('searchClients envía q solo si hay texto y decodifica UTF-8', () async {
      final service = await api();
      backend.on('GET', '/clients', (_) => http.Response.bytes(
          utf8.encode(jsonEncode({"clients": [{"id": 1, "name": "Logística Ñandú"}]})), 200,
          headers: {'content-type': 'application/json'})); // sin charset, como FastAPI
      final all = await backend.run(() => service.searchClients(query: '  '));
      final some = await backend.run(() => service.searchClients(query: 'ñan'));
      final calls = backend.calls('GET', '/clients');
      expect(calls[0].url.queryParameters, isEmpty);
      expect(calls[1].url.queryParameters, {"q": "ñan"});
      expect(all.single.name, 'Logística Ñandú');
      expect(some.single.id, 1);
      expect(calls[1].headers['Authorization'], startsWith('Bearer '));
    });

    test('setActivityStatus usa PATCH con solo el estado', () async {
      final service = await api();
      backend.json('PATCH', '/activities/5',
          {"id": 5, "datetime": "2026-01-01T10:00:00", "status": "completed", "products": []});
      final updated = await backend.run(() => service.setActivityStatus(5, ActivityStatus.completed));
      expect(jsonDecode(backend.calls('PATCH', '/activities/5').single.body), {"status": "completed"});
      expect(updated.status, ActivityStatus.completed);
    });

    test('deleteSale acepta 204 sin cuerpo; createSales devuelve las líneas creadas', () async {
      final service = await api();
      backend.on('DELETE', '/sales/3', (_) => http.Response('', 204));
      backend.json('POST', '/sales', {
        "ids": [1, 2],
        "sales": [
          {"id": 1, "amount_cents": 100},
          {"id": 2, "amount_cents": 200}
        ]
      }, status: 201);
      await backend.run(() => service.deleteSale(3));
      final sales = await backend.run(() => service.createSales(const SaleCreateInput(
          clientId: 1, saleDate: '2026-01-01', lines: [SaleLineInput(concept: 'x', amount: '1')])));
      expect(sales.map((s) => s.id), [1, 2]);
    });

    test('un fallo de red se convierte en ApiException(network)', () async {
      final service = await api();
      backend.on('GET', '/clients/9', (_) => throw http.ClientException('sin red'));
      await expectLater(backend.run(() => service.getClientDetail(9)),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.network)));
    });
  });
}
