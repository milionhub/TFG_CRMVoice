// H.3 · Clientes: listado, búsqueda con debounce en el backend, estados de
// carga/vacío/error y alta/edición de cliente. I.3.1: cabecera, contador,
// superficie única de listado, estados diferenciados y responsive.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/crm.dart';
import 'package:frontend/screens/client_detail_screen.dart';
import 'package:frontend/screens/clients_screen.dart';
import 'package:frontend/widgets/crm/client_form.dart';
import 'package:frontend/widgets/ui/cv_components.dart';
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
            expect(find.text('No encontramos clientes para esta búsqueda.'), findsOneWidget);
            expect(find.textContaining('«zzz»'), findsOneWidget);
            // Puede ser un error de escritura: no se propone crear un cliente
            expect(find.text('Crear el primero'), findsNothing);
            expect(find.text('Nuevo cliente'), findsOneWidget); // solo la acción de la cabecera

            await tester.tap(find.text('Limpiar búsqueda'));
            await tester.pumpAndSettle();
            expect(backend.calls('GET', '/clients').last.url.queryParameters['q'], isNull);
            expect(find.text('Orión Servicios'), findsOneWidget);
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
        expect(find.text('No tienes clientes todavía.'), findsOneWidget);
        expect(find.text('Crear el primero'), findsOneWidget);
        expect(find.byKey(const Key('clients-count')), findsNothing);
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

  // -------------------------------------------------------------------
  // I.3.1 · Presentación
  // -------------------------------------------------------------------

  group('I.3.1', () {
    void stubMany(int n) => backend.json('GET', '/clients', {
          "clients": [
            for (var i = 1; i <= n; i++)
              {"id": i, "name": "Cliente $i S.L.", if (i.isEven) "city": "Alicante"}
          ]
        });

    Future<void> pumpAt(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final auth = await loggedInAuth(backend);
      await tester.pumpWidget(appFor(auth, const ClientsScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('cabecera, contador y una única superficie con filas', (tester) => backend.run(() async {
          stubSearch();
          await pumpAt(tester, const Size(1440, 900));

          expect(find.text('Gestiona y consulta toda tu cartera de clientes.'), findsOneWidget);
          expect(find.widgetWithText(FilledButton, 'Nuevo cliente'), findsOneWidget);
          expect(find.text('2 clientes'), findsOneWidget);
          expect(find.byType(Card), findsNothing, reason: 'sin una tarjeta por cliente');
          expect(find.byType(CvSliverListSurface), findsOneWidget);
          expect(find.byType(CvEntityRow), findsNWidgets(2));

          // Mismo eje que el Inicio: contenido centrado con ancho máximo
          final row = tester.getRect(find.byType(CvEntityRow).first);
          expect(row.width, lessThanOrEqualTo(1080));
        }));

    testWidgets('el contador refleja la búsqueda', (tester) => backend.run(() async {
          stubSearch();
          await pumpAt(tester, const Size(1440, 900));
          await tester.enterText(find.widgetWithText(TextField, 'Buscar por razón social o alias'), 'neb');
          await tester.pump(ClientsContent.debounce);
          await tester.pumpAndSettle();
          expect(find.text('1 cliente encontrado'), findsOneWidget);
        }));

    testWidgets('toda la fila abre la ficha del cliente', (tester) => backend.run(() async {
          stubSearch();
          backend.json('GET', '/clients/1', clientDetailJson());
          backend.json('GET', '/activities', {"activities": []});
          await pumpAt(tester, const Size(1440, 900));

          // Pulsar cerca del borde derecho de la fila (no sobre el texto)
          final row = tester.getRect(find.byKey(const ValueKey('client-1')));
          await tester.tapAt(Offset(row.right - 60, row.center.dy));
          await tester.pumpAndSettle();
          expect(find.byType(ClientDetailScreen), findsOneWidget);
        }));

    const sizes = {
      'escritorio grande 2560x1440': Size(2560, 1440),
      'portátil 1366x768': Size(1366, 768),
      'tablet 900x1100': Size(900, 1100),
      'móvil 390x844': Size(390, 844),
      'móvil pequeño 360x640': Size(360, 640),
    };
    sizes.forEach((name, size) {
      testWidgets('sin desbordes: $name', (tester) => backend.run(() async {
            stubMany(40);
            await pumpAt(tester, size);
            expect(tester.takeException(), isNull);
            expect(find.text('40 clientes'), findsOneWidget);

            final button = tester.getRect(find.widgetWithText(FilledButton, 'Nuevo cliente'));
            expect(button.right, lessThanOrEqualTo(size.width));
            expect(button.height, greaterThanOrEqualTo(40));
            final search = tester.getRect(find.byType(TextField));
            final firstRow = tester.getRect(find.byType(CvEntityRow).first);
            expect(firstRow.height, greaterThanOrEqualTo(48), reason: 'objetivo táctil');
            expect(search.width, closeTo(firstRow.width, 1), reason: 'buscador y listado comparten ancho');

            await tester.scrollUntilVisible(find.text('Cliente 40 S.L.'), 400,
                scrollable: find.descendant(of: find.byType(ClientsContent), matching: find.byType(Scrollable)).first);
            expect(tester.takeException(), isNull);
          }));
    });
  });
}
