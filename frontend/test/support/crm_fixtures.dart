// Datos y utilidades comunes de los tests del CRM funcional (H.3).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/crm.dart';
import 'package:http/http.dart' as http;

import 'test_support.dart';

const nebulaClient = {
  "id": 1,
  "name": "Nebula Logística S.L.",
  "alias": "Nebula",
  "city": "Madrid",
  "province": "Madrid",
  "group_id": 3,
  "group_name": "Grupo Norte",
  "phone": "910000000",
  "email": "info@nebula.es",
  "cif": "B12345678",
};

const noraContact = {"id": 2, "name": "Nora Quintana", "role": "Compras", "email": "nora@nebula.es", "phone": null};

String isoDay(DateTime d) => formatApiDate(d);

Map<String, dynamic> listedActivity({
  int id = 10,
  required DateTime at,
  String status = 'pending',
  String comment = 'Presentar el monitor',
}) =>
    {
      "id": id,
      "fecha": "${formatApiDateTime(at)}:00",
      "client_id": 1,
      "contact_id": 2,
      "activity_type_id": 1,
      "cliente": "Nebula Logística S.L.",
      "contacto": "Nora Quintana",
      "accion": "Concertar reunión",
      "comentario": comment,
      "resolution_status": "manual",
      "status": status,
      "products": [
        {"product_id": 4, "product_raw": "Monitor Vela 24"},
      ],
    };

Map<String, dynamic> clientDetailJson({List<Map<String, dynamic>>? contacts, List<Map<String, dynamic>>? sales}) => {
      "client": nebulaClient,
      "contacts": contacts ?? [noraContact],
      "recent_activities": [],
      "sales": sales ??
          [
            {
              "id": 50,
              "client_id": 1,
              "client_name": "Nebula Logística S.L.",
              "contact_id": 2,
              "contact_name": "Nora Quintana",
              "product_id": 4,
              "product_name": "Monitor Vela 24",
              "concept": null,
              "quantity": 3,
              "amount_cents": 450050,
              "sale_date": "2026-09-15",
              "notes": null,
            }
          ],
      "revenue": {
        "invoices_cents": 1000000,
        "invoice_lines": 12,
        "my_sales_cents": 450050,
        "my_sales_lines": 1,
        "total_cents": 1450050,
        "note": "",
      },
      "discussed_products": [
        {"id": 4, "name": "Monitor Vela 24"}
      ],
    };

/// Catálogos que piden los formularios.
void stubCatalogs(FakeBackend backend) {
  backend.json('GET', '/activity-types', {
    "activity_types": [
      {"id": 1, "name": "Concertar reunión"},
      {"id": 2, "name": "Realizar llamada de seguimiento"},
    ]
  });
  backend.json('GET', '/products', {
    "products": [
      {"id": 4, "name": "Monitor Vela 24", "price": 189.0},
      {"id": 5, "name": "Teclado Brisa", "price": 39.9},
    ]
  });
  backend.on('GET', '/contacts', (request) {
    final clientId = request.url.queryParameters['client_id'];
    final contacts = clientId == '1'
        ? [
            {"id": 2, "name": "Nora Quintana"}
          ]
        : [
            {"id": 9, "name": "Otro Contacto"}
          ];
    return jsonResponse({"contacts": contacts});
  });
}

http.Response jsonResponse(Object body, {int status = 200}) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

Map<String, dynamic> lastJson(FakeBackend backend, String method, String path) =>
    jsonDecode(backend.calls(method, path).last.body) as Map<String, dynamic>;

/// Pantalla base con un botón que abre lo que haga [open].
Widget hostWith(Future<void> Function(BuildContext context) open) => Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(onPressed: () => open(context), child: const Text('abrir')),
        ),
      ),
    );

Future<void> tapText(WidgetTester tester, String text, {bool last = false}) async {
  final finder = last ? find.text(text).last : find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enterField(WidgetTester tester, String label, String value) async {
  final finder = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}
