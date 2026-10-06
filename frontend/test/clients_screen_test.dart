// H.3 · Clientes: listado, búsqueda con debounce en el backend, estados de
// carga/vacío/error y alta/edición de cliente.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/crm.dart';
import 'package:frontend/screens/client_detail_screen.dart';
import 'package:frontend/screens/clients_screen.dart';
import 'package:frontend/widgets/crm/client_form.dart';
import 'package:http/http.dart' as http;

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpClients(WidgetTester tester) async {
    useDesktopSurface(tester);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const ClientsScreen()));
  }

  void stubSearch() {
    backend.on('GET', '/clients', (request) {
      final q = request.url.queryParameters['q'];
      final all = [
        {"id": 1, "name": "Nebula Logística S.L.", "alias": "Nebula", "city": "Madrid"},
        {"id": 2, "name": "Orión Servicios"},
      ];
      final filtered = q == null ? all : all.where((c) => (c["name"] as String).toLowerCase().contains(q)).toList();
      return jsonResponse({"clients": filtered});
    });
  }

  testWidgets('carga y lista los clientes con alias y población', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        backend.on('GET', '/clients', (_) => pending.future);
        await pumpClients(tester);
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        pending.complete(jsonResponse({
          "clients": [
            {"id": 1, "name": "Nebula Logística S.L.", "alias": "Nebula", "city": "Madrid"},
            {"id": 2, "name": "Orión Servicios"},
          ]
        }));
        await tester.pumpAndSettle();

        expect(find.text('Nebula Logística S.L.'), findsOneWidget);
        expect(find.text('Nebula · Madrid'), findsOneWidget);
        expect(find.text('Orión Servicios'), findsOneWidget);
        expect(find.text('Clientes'), findsWidgets); // destino en la navegación
      }));

  testWidgets('la búsqueda espera a que se deje de escribir y usa ?q= del backend',
      (tester) => backend.run(() async {
            stubSearch();
            await pumpClients(tester);
            await tester.pumpAndSettle();

            final search = find.widgetWithText(TextField, 'Buscar por razón social o alias');
            await tester.enterText(search, 'n');
            await tester.pump(const Duration(milliseconds: 100));
            await tester.enterText(search, 'ne');
            await tester.pump(const Duration(milliseconds: 100));
            await tester.enterText(search, 'neb');
            await tester.pump(ClientsContent.debounce);
            await tester.pumpAndSettle();

            final queries = backend.calls('GET', '/clients').map((r) => r.url.queryParameters['q']).toList();
            expect(queries, [null, 'neb']);
            expect(find.text('Nebula Logística S.L.'), findsOneWidget);
            expect(find.text('Orión Servicios'), findsNothing);

            await tester.enterText(search, 'zzz');
            await tester.pump(ClientsContent.debounce);
            await tester.pumpAndSettle();
            expect(find.text('Ningún cliente coincide con «zzz».'), findsOneWidget);
          }));

  testWidgets('error de carga: mensaje sin detalles técnicos y Reintentar', (tester) => backend.run(() async {
        var calls = 0;
        backend.on('GET', '/clients', (_) {
          calls++;
          return calls == 1
              ? http.Response('Traceback (most recent call last)', 500)
              : jsonResponse({"clients": [{"id": 2, "name": "Orión Servicios"}]});
        });
        await pumpClients(tester);
        await tester.pumpAndSettle();

        expect(find.textContaining('Error del servidor'), findsOneWidget);
        expect(find.textContaining('Traceback'), findsNothing);

        await tester.tap(find.text('Reintentar'));
        await tester.pumpAndSettle();
        expect(find.text('Orión Servicios'), findsOneWidget);
      }));

  testWidgets('sin clientes: estado vacío con acción de crear', (tester) => backend.run(() async {
        backend.json('GET', '/clients', {"clients": []});
        await pumpClients(tester);
        await tester.pumpAndSettle();
        expect(find.text('Todavía no hay clientes.'), findsOneWidget);
        expect(find.text('Crear el primero'), findsOneWidget);
      }));

  testWidgets('nuevo cliente: valida, crea, avisa del parecido y abre la ficha', (tester) => backend.run(() async {
        stubSearch();
        backend.json('POST', '/clients', {
          ...nebulaClient,
          "id": 1,
          "warnings": [
            {
              "code": "similar",
              "field": "client",
              "message": "Se parece a un cliente que ya existe: «Nebulosa S.A.».",
              "blocking": false,
              "candidates": []
            }
          ],
        }, status: 201);
        backend.json('GET', '/clients/1', clientDetailJson());
        backend.json('GET', '/activities', {"activities": []});
        await pumpClients(tester);
        await tester.pumpAndSettle();

        await tapText(tester, 'Nuevo cliente');
        expect(find.text('Nuevo cliente'), findsWidgets);

        // Validación local: nada se envía
        await tapText(tester, 'Crear cliente');
        expect(find.text('La razón social es obligatoria'), findsOneWidget);
        await enterField(tester, 'Razón social *', 'Nebula Logística S.L.');
        await enterField(tester, 'Email', 'no-es-email');
        await tapText(tester, 'Crear cliente');
        expect(find.text('Email no válido'), findsOneWidget);
        expect(backend.calls('POST', '/clients'), isEmpty);

        await enterField(tester, 'Email', 'info@nebula.es');
        await enterField(tester, 'Población', 'Madrid');
        await tapText(tester, 'Crear cliente');

        expect(lastJson(backend, 'POST', '/clients'), {
          "name": "Nebula Logística S.L.",
          "alias": null,
          "city": "Madrid",
          "province": null,
          "group_id": null,
          "phone": null,
          "email": "info@nebula.es",
          "cif": null,
        });
        expect(find.text('Cliente guardado con un aviso'), findsOneWidget);
        expect(find.textContaining('Nebulosa S.A.'), findsOneWidget);
        await tapText(tester, 'Entendido');

        expect(find.byType(ClientDetailScreen), findsOneWidget);
      }));

  testWidgets('duplicado (409): el formulario sigue abierto con el mensaje del servidor',
      (tester) => backend.run(() async {
            backend.json('POST', '/clients', {
              "detail": "Ya existe el cliente «Nebula Logística S.L.».",
              "code": "duplicate_client",
              "existing_id": 1,
              "issues": [
                {"code": "duplicate", "field": "client", "message": "Ya existe el cliente «Nebula Logística S.L.».", "blocking": true}
              ]
            }, status: 409);
            useDesktopSurface(tester);
            final auth = await loggedInAuth(backend);
            await tester.pumpWidget(appFor(auth, hostWith((context) => openClientForm(context))));
            await tapText(tester, 'abrir');

            await enterField(tester, 'Razón social *', 'nebula logistica');
            await tapText(tester, 'Crear cliente');

            expect(find.text('Ya existe el cliente «Nebula Logística S.L.».'), findsOneWidget);
            expect(find.text('Nuevo cliente'), findsOneWidget);
            expect(backend.calls('POST', '/clients'), hasLength(1));
          }));

  testWidgets('editar cliente: PUT completo que conserva el grupo y evita el doble envío',
      (tester) => backend.run(() async {
            final pending = Completer<http.Response>();
            backend.on('PUT', '/clients/1', (_) => pending.future);
            useDesktopSurface(tester);
            final auth = await loggedInAuth(backend);
            await tester.pumpWidget(appFor(
                auth, hostWith((context) => openClientForm(context, client: Client.fromJson(nebulaClient)))));
            await tapText(tester, 'abrir');

            expect(find.text('Editar cliente'), findsOneWidget);
            expect(find.text('Grupo Norte'), findsOneWidget);
            await enterField(tester, 'Alias / nombre comercial', 'Nebula Log');
            await tester.tap(find.text('Guardar cambios'));
            await tester.pump();
            // Mientras guarda, el botón está desactivado
            expect(find.text('Guardando...'), findsOneWidget);
            await tester.tap(find.text('Guardando...'), warnIfMissed: false);
            await tester.pump();

            pending.complete(jsonResponse({...nebulaClient, "alias": "Nebula Log", "warnings": []}));
            await tester.pumpAndSettle();

            expect(backend.calls('PUT', '/clients/1'), hasLength(1));
            final body = lastJson(backend, 'PUT', '/clients/1');
            expect(body["alias"], 'Nebula Log');
            expect(body["group_id"], 3);
            expect(find.text('Editar cliente'), findsNothing);
          }));
}
