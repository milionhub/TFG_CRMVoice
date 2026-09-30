// HistoryScreen (P0): carga, lista, vacío, borrado y error (FE-D7-01).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:http/http.dart' as http;

import 'support/test_support.dart';

const activity = {
  "id": 1,
  "fecha": "2026-10-01T10:30:00",
  "client_id": 1,
  "contact_id": 2,
  "activity_type_id": 1,
  "cliente": "Nebula Logística S.L.",
  "contacto": "Nora Quintana",
  "accion": "Concertar reunión",
  "comentario": "Presentar el monitor",
  "resolution_status": "high",
  "products": [
    {"product_id": 4, "product_raw": "Monitor Vela 24"},
  ],
};

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    backend.json('GET', '/clients', {"clients": [{"id": 1, "name": "Nebula Logística S.L."}]});
    backend.json('GET', '/activity-types', {"activity_types": [{"id": 1, "name": "Concertar reunión"}]});
    backend.json('GET', '/products', {"products": [{"id": 4, "name": "Monitor Vela 24", "price": 189.0}]});
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpHistory(WidgetTester tester) async {
    useDesktopSurface(tester);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const HistoryScreen()));
  }

  testWidgets('muestra carga y después la lista con cliente, contacto, acción y productos',
      (tester) => backend.run(() async {
            final pending = Completer<http.Response>();
            backend.on('GET', '/activities', (_) => pending.future);
            await pumpHistory(tester);
            await tester.pump();

            expect(find.byType(CircularProgressIndicator), findsOneWidget);

            pending.complete(http.Response(jsonEncode({"count": 1, "activities": [activity]}), 200,
                headers: {'content-type': 'application/json; charset=utf-8'}));
            await tester.pumpAndSettle();

            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(find.textContaining('Nebula Logística S.L.'), findsWidgets);
            expect(find.textContaining('Nora Quintana'), findsWidgets);
            expect(find.textContaining('Concertar reunión'), findsWidgets);
            expect(find.textContaining('Monitor Vela 24'), findsWidgets);
            expect(backend.calls('GET', '/activities').single.headers['Authorization'], startsWith('Bearer '));
          }));

  testWidgets('sin actividades muestra el mensaje de lista vacía', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"count": 0, "activities": []});
        await pumpHistory(tester);
        await tester.pumpAndSettle();

        expect(find.text('No hay actividades registradas'), findsOneWidget);
      }));

  testWidgets('borrar: confirma, llama a DELETE y recarga la lista', (tester) => backend.run(() async {
        var listed = 0;
        backend.on('GET', '/activities', (_) {
          listed++;
          final items = listed == 1 ? [activity] : [];
          return http.Response(jsonEncode({"activities": items}), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        });
        backend.json('DELETE', '/activities/1', {"success": true});
        await pumpHistory(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Eliminar'));
        await tester.pumpAndSettle();

        expect(backend.calls('DELETE', '/activities/1'), hasLength(1));
        expect(listed, 2);
        expect(find.text('No hay actividades registradas'), findsOneWidget);
      }));

  testWidgets('borrar y cancelar: no llama a DELETE', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"activities": [activity]});
        await pumpHistory(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();

        expect(backend.calls('DELETE', '/activities/1'), isEmpty);
        expect(find.textContaining('Nebula Logística S.L.'), findsWidgets);
      }));

  testWidgets('FE-D7-01: si falla la carga no se queda cargando indefinidamente', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"detail": "error"}, status: 500);
        await pumpHistory(tester);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(find.byType(CircularProgressIndicator), findsNothing);
      }),
      skip: true); // FE-D7-01: _loadActivities no captura errores -> spinner infinito y error no controlado
}
