// NewActivityScreen (P0): muestra el análisis de voz, guarda con el payload
// completo (productos incluidos), gestiona el {"error"} del backend y el modo
// edición carga los catálogos. Errores de red: FE-D7-02.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/new_activity_screen.dart';
import 'package:http/http.dart' as http;

import 'support/test_support.dart';

final Map<String, dynamic> analysis = {
  "texto": "Concertar reunión mañana con Nora de Nebula para el monitor Vela 24",
  "cliente_detectado": "Nebula",
  "contacto_detectado": "Nora",
  "cliente_id": 1,
  "contacto_id": 2,
  "cliente_nombre": "Nebula Logística S.L.",
  "contacto_nombre": "Nora Quintana",
  "accion_detectada": "Concertar reunión",
  "activity_type_id": 1,
  "fecha_detectada": "2026-10-02T10:00:00",
  "products_detected": [
    {"product_id": 4, "product_raw": "Monitor Vela 24", "confidence": 100},
  ],
  "resolution_status": "exact",
  "overall_confidence": 100,
};

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  /// Pantalla abierta con push desde una ruta base (como hace RecorderCard).
  Future<void> pumpNewActivity(WidgetTester tester, {Map<String, dynamic>? result}) async {
    useDesktopSurface(tester);
    final AuthProvider auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(
      auth,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => NewActivityScreen(result: result ?? analysis))),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Guardar actividad'));
    await tester.tap(find.text('Guardar actividad'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('muestra acción, cliente, contacto, transcripción y productos detectados',
      (tester) => backend.run(() async {
            await pumpNewActivity(tester);

            expect(find.text('Nueva actividad'), findsOneWidget);
            expect(find.text('Concertar reunión'), findsOneWidget);
            expect(find.text('Nebula Logística S.L.'), findsOneWidget);
            expect(find.text('Nora Quintana'), findsOneWidget);
            expect(find.textContaining('monitor Vela 24'), findsWidgets);
            expect(find.textContaining('Monitor Vela 24'), findsWidgets);
          }));

  testWidgets('guardar envía el payload completo (ids, fecha, texto y productos) y vuelve atrás',
      (tester) => backend.run(() async {
            backend.json('POST', '/activities', {"success": true, "activity_id": 10});
            await pumpNewActivity(tester);

            await save(tester);
            expect(find.text('Actividad guardada correctamente'), findsOneWidget);
            await tester.pumpAndSettle();

            final payload = jsonDecode(backend.calls('POST', '/activities').single.body);
            expect(payload, {
              "cliente_id": 1,
              "contacto_id": 2,
              "activity_type_id": 1,
              "fecha_detectada": "2026-10-02T10:00:00",
              "texto": analysis["texto"],
              "products_detected": analysis["products_detected"],
              "cliente_detectado": "Nebula",
              "contacto_detectado": "Nora",
              "accion_detectada": "Concertar reunión",
              "resolution_status": "exact",
              "overall_confidence": 100,
            });
            expect(find.byType(NewActivityScreen), findsNothing); // Navigator.pop
          }));

  testWidgets('si el backend responde 422 {"detail"} se muestra el mensaje y no se cierra',
      (tester) => backend.run(() async {
            backend.json('POST', '/activities', {"detail": "Cliente obligatorio"}, status: 422);
            await pumpNewActivity(tester, result: {...analysis, "cliente_id": null});

            await save(tester);

            expect(find.text('Cliente obligatorio'), findsOneWidget);
            expect(find.byType(NewActivityScreen), findsOneWidget);
            expect(jsonDecode(backend.calls('POST', '/activities').single.body)["cliente_id"], isNull);
          }));

  testWidgets('duplicado detectado por el backend se muestra como error', (tester) => backend.run(() async {
        backend.json('POST', '/activities', {"detail": "Actividad duplicada detectada"}, status: 409);
        await pumpNewActivity(tester);

        await save(tester);

        expect(find.text('Actividad duplicada detectada'), findsOneWidget);
        expect(find.byType(NewActivityScreen), findsOneWidget);
      }));

  testWidgets('modo edición: carga tipos, clientes, productos y contactos del cliente y muestra los selectores',
      (tester) => backend.run(() async {
            backend.json('GET', '/activity-types', {"activity_types": [{"id": 1, "name": "Concertar reunión"}]});
            backend.json('GET', '/clients', {"clients": [{"id": 1, "name": "Nebula Logística S.L."}]});
            backend.json('GET', '/products', {"products": [{"id": 4, "name": "Monitor Vela 24", "price": 189.0}]});
            backend.json('GET', '/contacts', {"contacts": [{"id": 2, "name": "Nora Quintana"}]});
            await pumpNewActivity(tester);

            await tester.tap(find.byIcon(Icons.edit_outlined));
            await tester.pumpAndSettle();

            expect(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.close)), findsOneWidget);
            expect(find.widgetWithText(DropdownButtonFormField<int>, 'Acción'), findsOneWidget);
            expect(find.widgetWithText(DropdownButtonFormField<int>, 'Cliente'), findsOneWidget);
            expect(find.widgetWithText(DropdownButtonFormField<int>, 'Contacto'), findsOneWidget);
            expect(backend.calls('GET', '/contacts').single.url.queryParameters, {"client_id": "1"});
          }));

  testWidgets('FE-D7-02: un fallo de red o un 500 al guardar muestra un error', (tester) => backend.run(() async {
        backend.on('POST', '/activities', (_) => http.Response('Internal Server Error', 500));
        await pumpNewActivity(tester);

        await save(tester);

        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(NewActivityScreen), findsOneWidget);
      }),
      skip: true); // FE-D7-02: createActivity lanza (JSON inválido/red) y onPressed no lo captura: sin aviso

  testWidgets('FE-D7-03: mientras se guarda no se puede enviar dos veces', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        backend.on('POST', '/activities', (_) => pending.future);
        await pumpNewActivity(tester);

        await save(tester);
        await save(tester);
        pending.complete(http.Response('{"success": true, "activity_id": 1}', 200));
        await tester.pumpAndSettle();

        expect(backend.calls('POST', '/activities'), hasLength(1));
      }),
      skip: true); // FE-D7-03: el botón no se deshabilita durante el guardado (doble envío)
}
