// H.3 · Ficha de cliente: secciones, contactos (alta/edición), actividades
// con estado, ventas (alta multilínea, edición y borrado) y resumen.
// I.3.2: ficha dentro del AppShell, cabecera, secciones, límite inicial de
// actividades, vuelta a Clientes, estados vacíos y responsive.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/crm.dart';
import 'package:frontend/screens/client_detail_screen.dart';
import 'package:frontend/screens/clients_screen.dart';
import 'package:frontend/widgets/crm/activity_actions.dart';
import 'package:frontend/widgets/crm/sale_form.dart';
import 'package:frontend/widgets/shell/app_shell.dart';
import 'package:frontend/widgets/ui/cv_components.dart';

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';

void main() {
  late FakeBackend backend;
  final yesterday = DateTime.now().subtract(const Duration(days: 1));

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    stubCatalogs(backend);
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpDetail(WidgetTester tester) async {
    useDesktopSurface(tester);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const ClientDetailScreen(clientId: 1)));
    await tester.pumpAndSettle();
  }

  void stubDetail({List<Map<String, dynamic>>? activities}) {
    backend.json('GET', '/clients/1', clientDetailJson());
    backend.json('GET', '/activities', {"activities": activities ?? [listedActivity(at: yesterday)]});
  }

  testWidgets('muestra datos, contactos, actividades con estado, ventas y resumen por origen',
      (tester) => backend.run(() async {
            stubDetail();
            await pumpDetail(tester);

            expect(backend.calls('GET', '/activities').single.url.queryParameters, {"client_id": "1"});
            expect(find.text('Nebula Logística S.L.'), findsWidgets);
            expect(find.text('Madrid'), findsOneWidget); // ubicación
            expect(find.text('Grupo Norte'), findsOneWidget);
            // Contactos
            expect(find.text('Contactos (1)'), findsOneWidget);
            expect(find.text('Compras · nora@nebula.es'), findsOneWidget);
            // Actividades (pendiente en el pasado = vencida)
            expect(find.text('Actividad reciente'), findsOneWidget);
            expect(find.text('1 actividad · 1 pendiente'), findsOneWidget);
            expect(find.text('Pendiente · vencida'), findsOneWidget);
            // El comentario no se muestra en la fila (se ve al abrir la actividad)
            expect(find.text('Presentar el monitor'), findsNothing);
            // Ventas
            expect(find.text('Monitor Vela 24 × 3'), findsOneWidget);
            expect(find.text('4.500,50 €'), findsWidgets);
            // Resumen: facturas históricas y ventas propias por separado
            expect(find.text('Tus ventas registradas'), findsOneWidget);
            expect(find.text('Facturación histórica'), findsOneWidget);
            expect(find.textContaining('de todos los comerciales'), findsOneWidget);
            expect(find.text('10.000,00 €'), findsOneWidget);
            expect(find.text('14.500,50 €'), findsOneWidget);
          }));

  testWidgets('cliente inexistente: mensaje claro', (tester) => backend.run(() async {
        backend.json('GET', '/clients/1', {"detail": "Cliente no encontrado"}, status: 404);
        backend.json('GET', '/activities', {"activities": []});
        await pumpDetail(tester);
        expect(find.text('Cliente no encontrado.'), findsOneWidget);
        expect(find.text('Reintentar'), findsOneWidget);
      }));

  testWidgets('añadir contacto: cliente fijo, valida, POST con client_id y recarga la ficha',
      (tester) => backend.run(() async {
            stubDetail();
            backend.json('POST', '/contacts', {"id": 8, "client_id": 1, "name": "Carlos Ruiz"}, status: 201);
            await pumpDetail(tester);

            await tapText(tester, 'Añadir');
            expect(find.text('Nuevo contacto'), findsOneWidget);
            await tapText(tester, 'Crear contacto');
            expect(find.text('El nombre es obligatorio'), findsOneWidget);

            await enterField(tester, 'Nombre *', 'Carlos Ruiz');
            await enterField(tester, 'Teléfono', '12');
            await tapText(tester, 'Crear contacto');
            expect(find.textContaining('Teléfono no válido'), findsOneWidget);
            expect(backend.calls('POST', '/contacts'), isEmpty);

            await enterField(tester, 'Teléfono', '600 000 000');
            await tapText(tester, 'Crear contacto');

            expect(lastJson(backend, 'POST', '/contacts'),
                {"client_id": 1, "name": "Carlos Ruiz", "role": null, "email": null, "phone": "600 000 000"});
            expect(find.text('Nuevo contacto'), findsNothing);
            expect(backend.calls('GET', '/clients/1'), hasLength(2)); // ficha recargada
          }));

  testWidgets('editar contacto: PUT sin client_id; el duplicado se explica en el formulario',
      (tester) => backend.run(() async {
            stubDetail();
            backend.json('PUT', '/contacts/2', {
              "detail": "Nora ya es un contacto de este cliente.",
              "code": "duplicate_contact",
              "existing_id": 3,
              "issues": [
                {"code": "duplicate", "field": "contact", "message": "Nora ya es un contacto de este cliente.", "blocking": true}
              ]
            }, status: 409);
            await pumpDetail(tester);

            await tester.tap(find.byTooltip('Editar contacto'));
            await tester.pumpAndSettle();
            expect(find.text('Editar contacto'), findsWidgets);
            await enterField(tester, 'Nombre *', 'Nora');
            await tapText(tester, 'Guardar cambios');

            final body = lastJson(backend, 'PUT', '/contacts/2');
            expect(body.containsKey('client_id'), isFalse);
            expect(body["name"], 'Nora');
            expect(find.text('Nora ya es un contacto de este cliente.'), findsWidgets);
          }));

  testWidgets('estado rápido de una actividad: PATCH y recarga', (tester) => backend.run(() async {
        stubDetail();
        backend.json('PATCH', '/activities/10',
            {"id": 10, "datetime": "2026-01-01T10:00:00", "status": "completed", "products": []});
        await pumpDetail(tester);

        await tester.tap(find.byTooltip('Acciones').first);
        await tester.pumpAndSettle();
        await tapText(tester, 'Marcar completada');

        expect(lastJson(backend, 'PATCH', '/activities/10'), {"status": "completed"});
        expect(backend.calls('GET', '/activities'), hasLength(2));
      }));

  testWidgets('nueva actividad desde la ficha: el cliente es fijo y no se pide la lista de clientes',
      (tester) => backend.run(() async {
            stubDetail(activities: []);
            await pumpDetail(tester);

            await tapText(tester, 'Nueva');
            expect(find.text('Nueva actividad'), findsOneWidget);
            // El contacto se limita a los del cliente de la ficha
            expect(backend.calls('GET', '/contacts').single.url.queryParameters, {"client_id": "1"});
            expect(backend.calls('GET', '/clients'), isEmpty);
          }));

  testWidgets('borrar venta: pide confirmación; cancelar no borra, confirmar sí', (tester) => backend.run(() async {
        stubDetail();
        backend.json('DELETE', '/sales/50', null);
        await pumpDetail(tester);

        Future<void> openDelete() async {
          await tester.ensureVisible(find.byTooltip('Acciones').last);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Acciones').last);
          await tester.pumpAndSettle();
          await tapText(tester, 'Eliminar venta');
        }

        await openDelete();
        await tapText(tester, 'Cancelar');
        expect(backend.calls('DELETE', '/sales/50'), isEmpty);

        await openDelete();
        expect(find.textContaining('4.500,50 €'), findsWidgets);
        await tapText(tester, 'Eliminar');
        expect(backend.calls('DELETE', '/sales/50'), hasLength(1));
        expect(backend.calls('GET', '/clients/1'), hasLength(2));
      }));

  group('formulario de venta', () {
    final client = Client.fromJson(nebulaClient);
    final contacts = [Contact.fromJson(noraContact)!];

    Future<void> pumpSaleForm(WidgetTester tester, {Sale? sale}) async {
      useDesktopSurface(tester);
      final auth = await loggedInAuth(backend);
      await tester.pumpWidget(appFor(
          auth, hostWith((context) => openSaleForm(context, client: client, contacts: contacts, sale: sale))));
      await tapText(tester, 'abrir');
    }

    Finder amountField(int index) => find.widgetWithText(TextFormField, 'Importe total *').at(index);
    Finder conceptField(int index) => find.widgetWithText(TextFormField, 'Concepto *').at(index);

    testWidgets('varias líneas en una sola operación: añadir, quitar, máximo 5, total y POST único',
        (tester) => backend.run(() async {
              backend.json('POST', '/sales', {"ids": [1, 2], "sales": []}, status: 201);
              await pumpSaleForm(tester);
              expect(find.text('Registrar venta'), findsOneWidget);

              for (var i = 0; i < 4; i++) {
                await tapText(tester, 'Añadir línea');
              }
              expect(find.text('Línea 5'), findsOneWidget);
              expect(find.text('Máximo 5 líneas'), findsOneWidget);

              // Quitar tres líneas: quedan dos
              for (var i = 0; i < 3; i++) {
                await tester.tap(find.byTooltip('Quitar línea').last);
                await tester.pumpAndSettle();
              }
              expect(find.text('Línea 3'), findsNothing);

              // Línea 1: producto del catálogo; línea 2: concepto libre
              await tester.tap(find.byTooltip('Elegir producto del catálogo').first);
              await tester.pumpAndSettle();
              await tapText(tester, 'Monitor Vela 24');
              await tester.enterText(find.widgetWithText(TextFormField, 'Cantidad').first, '2');
              await tester.enterText(amountField(0), '4.500');
              await tester.enterText(conceptField(0), 'Instalación');
              await tester.enterText(amountField(1), '120,5');
              await tester.pump();

              expect(find.text('= 4.500,00 €'), findsOneWidget);
              expect(find.text('= 120,50 €'), findsOneWidget);
              expect(find.text('4.620,50 €'), findsOneWidget); // total

              await tapText(tester, 'Guardar venta');

              expect(backend.calls('POST', '/sales'), hasLength(1));
              final body = lastJson(backend, 'POST', '/sales');
              expect(body["client_id"], 1);
              expect(body["sale_date"], isoDay(DateTime.now()));
              expect(body["lines"], [
                {"product_id": 4, "concept": null, "quantity": 2, "amount": "4.500"},
                {"product_id": null, "concept": "Instalación", "quantity": null, "amount": "120,5"},
              ]);
              expect(find.text('Registrar venta'), findsNothing);
            }));

    testWidgets('importe ambiguo o línea sin producto ni concepto: no se envía nada',
        (tester) => backend.run(() async {
              await pumpSaleForm(tester);
              await tester.enterText(amountField(0), '4,500');
              await tester.pump();
              await tapText(tester, 'Guardar venta');

              expect(find.text('Importe ambiguo: escribe 4.500 o 4500,00'), findsOneWidget);
              expect(find.text('Indica un producto o un concepto'), findsOneWidget);
              expect(backend.calls('POST', '/sales'), isEmpty);
            }));

    testWidgets('error del servidor en una línea se muestra en esa línea', (tester) => backend.run(() async {
          backend.json('POST', '/sales', {
            "detail": "La fecha de una venta no puede ser futura.",
            "issues": [
              {"code": "not_found", "field": "lines[1].product", "message": "El producto no existe.", "blocking": true},
            ]
          }, status: 422);
          await pumpSaleForm(tester);
          await tapText(tester, 'Añadir línea');
          await tester.enterText(conceptField(0), 'A');
          await tester.enterText(amountField(0), '10');
          await tester.enterText(conceptField(1), 'B');
          await tester.enterText(amountField(1), '20');
          await tapText(tester, 'Guardar venta');

          expect(find.text('Línea 2 · Producto: El producto no existe.'), findsOneWidget);
          expect(find.text('El producto no existe.'), findsOneWidget); // bajo el campo de la línea 2
          expect(find.text('Registrar venta'), findsOneWidget);
        }));

    testWidgets('editar venta: una línea, importe en céntimos convertido sin flotantes, PUT plano',
        (tester) => backend.run(() async {
              backend.json('PUT', '/sales/50', {"id": 50, "amount_cents": 450050});
              final sale = Sale.fromJson(clientDetailJson()["sales"][0])!;
              await pumpSaleForm(tester, sale: sale);

              expect(find.text('Editar venta'), findsOneWidget);
              expect(find.text('Añadir línea'), findsNothing);
              expect(find.text('4500,50'), findsOneWidget);
              expect(find.text('Monitor Vela 24'), findsOneWidget);

              await tapText(tester, 'Guardar cambios');
              expect(lastJson(backend, 'PUT', '/sales/50'), {
                "client_id": 1,
                "contact_id": 2,
                "sale_date": "2026-09-15",
                "notes": null,
                "product_id": 4,
                "concept": null,
                "quantity": 3,
                "amount": "4500,50",
              });
            }));
  });

  // -------------------------------------------------------------------
  // I.3.2 · Presentación y navegación
  // -------------------------------------------------------------------

  group('I.3.2', () {
    List<Map<String, dynamic>> manyActivities(int n) => [
          for (var i = 0; i < n; i++)
            listedActivity(id: 100 + i, at: yesterday.subtract(Duration(days: i)), comment: 'Comentario $i')
        ];

    Future<void> pumpAt(WidgetTester tester, Size size, Widget home) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final auth = await loggedInAuth(backend);
      await tester.pumpWidget(appFor(auth, home));
      await tester.pumpAndSettle();
    }

    ShellNavItem navItem(WidgetTester tester, String label) => tester
        .widgetList<ShellNavItem>(find.descendant(of: find.byType(Sidebar), matching: find.byType(ShellNavItem)))
        .firstWhere((i) => i.destination.label == label);

    double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

    testWidgets('dentro del shell con Clientes activo; cabecera del cliente y secciones en orden',
        (tester) => backend.run(() async {
              stubDetail();
              await pumpAt(tester, const Size(1440, 1000), const ClientDetailScreen(clientId: 1));

              expect(find.byType(Sidebar), findsOneWidget);
              expect(navItem(tester, 'Clientes').selected, isTrue);
              expect(find.byType(AppBar), findsNothing, reason: 'sin la barra propia anterior');

              // Cabecera: el propio cliente (sin tarjeta «Datos del cliente»)
              expect(find.text('Datos del cliente'), findsNothing);
              expect(find.text('Nebula Logística S.L.'), findsOneWidget);
              expect(find.text('Nebula · Madrid'), findsOneWidget);
              expect(find.byTooltip('Editar cliente'), findsOneWidget);
              expect(find.byTooltip('Actualizar'), findsOneWidget);

              // Información | Contactos en dos columnas
              expect(top(tester, 'Información'), top(tester, 'Contactos (1)'));
              expect(find.text('B12345678'), findsOneWidget);
              expect(find.text('info@nebula.es'), findsOneWidget);

              // Orden vertical
              expect(top(tester, 'Información'), lessThan(top(tester, 'Resumen comercial')));
              expect(top(tester, 'Resumen comercial'), lessThan(top(tester, 'Actividad reciente')));
              expect(top(tester, 'Actividad reciente'), lessThan(top(tester, 'Ventas')));

              // Resumen: tres cifras comparables en una fila y productos
              expect(top(tester, 'Tus ventas registradas'), top(tester, 'Facturación histórica'));
              expect(top(tester, 'Facturación histórica'), top(tester, 'Total'));
              // Los productos tratados ya no se muestran en la ficha
              expect(find.text('Productos tratados en tus actividades'), findsNothing);
              expect(find.text('Monitor Vela 24'), findsNothing);
            }));

    testWidgets('actividad reciente: 5 al inicio, «Ver todas» muestra el resto y «Ver menos» vuelve',
        (tester) => backend.run(() async {
              stubDetail(activities: manyActivities(7));
              await pumpAt(tester, const Size(1440, 1000), const ClientDetailScreen(clientId: 1));

              expect(find.text('7 actividades · 7 pendientes'), findsOneWidget);
              expect(find.byType(ActivityActionsMenu), findsNWidgets(5));
              await tapText(tester, 'Ver todas (7)');
              expect(find.byType(ActivityActionsMenu), findsNWidgets(7));
              await tapText(tester, 'Ver menos');
              expect(find.byType(ActivityActionsMenu), findsNWidgets(5));
            }));

    testWidgets('el comentario no aparece en la fila pero sigue al abrir la actividad',
        (tester) => backend.run(() async {
              stubDetail();
              await pumpAt(tester, const Size(1440, 1000), const ClientDetailScreen(clientId: 1));
              expect(find.text('Presentar el monitor'), findsNothing);

              await tapText(tester, 'Concertar reunión');
              expect(find.text('Presentar el monitor'), findsOneWidget); // en el formulario
            }));

    testWidgets('«← Clientes» vuelve al listado abierto antes (pop, sin acumular)', (tester) => backend.run(() async {
          stubDetail();
          backend.json('GET', '/clients', {
            "clients": [
              {"id": 1, "name": "Nebula Logística S.L."}
            ]
          });
          await pumpAt(tester, const Size(1440, 1000), const ClientsScreen());
          await tester.tap(find.text('Nebula Logística S.L.'));
          await tester.pumpAndSettle();
          expect(find.byType(ClientDetailScreen), findsOneWidget);

          await tester.tap(find.widgetWithText(TextButton, 'Clientes'));
          await tester.pumpAndSettle();
          expect(find.byType(ClientDetailScreen), findsNothing);
          expect(find.byType(ClientsScreen), findsOneWidget);
          expect(tester.state<NavigatorState>(find.byType(Navigator).first).canPop(), isFalse);
          expect(backend.calls('GET', '/clients'), hasLength(2), reason: 'el listado se recarga al volver');
        }));

    testWidgets('abierta desde otra sección, «← Clientes» y la barra lateral llevan al listado',
        (tester) => backend.run(() async {
              stubDetail();
              backend.json('GET', '/clients', {"clients": []});
              await pumpAt(
                  tester,
                  const Size(1440, 1000),
                  hostWith((context) =>
                      Navigator.push(context, SectionRoute<void>(builder: (_) => const ClientDetailScreen(clientId: 1)))));
              await tapText(tester, 'abrir');
              expect(find.byType(ClientDetailScreen), findsOneWidget);

              // Clientes está activo, pero desde la ficha vuelve al listado
              await tester.tap(find.descendant(of: find.byType(Sidebar), matching: find.text('Clientes')));
              await tester.pumpAndSettle();
              expect(find.byType(ClientsScreen), findsOneWidget);
              expect(tester.state<NavigatorState>(find.byType(Navigator).first).canPop(), isFalse);
            }));

    testWidgets('editar cliente sigue abriendo el formulario', (tester) => backend.run(() async {
          stubDetail();
          await pumpAt(tester, const Size(1440, 1000), const ClientDetailScreen(clientId: 1));
          await tapText(tester, 'Editar');
          expect(find.text('Editar cliente'), findsWidgets);
        }));

    testWidgets('datos parciales y secciones vacías: estados compactos, sin etiquetas vacías',
        (tester) => backend.run(() async {
              backend.json('GET', '/clients/1', {
                ...clientDetailJson(contacts: [], sales: []),
                "client": {"id": 1, "name": "Solo Nombre"},
                "discussed_products": [],
              });
              backend.json('GET', '/activities', {"activities": []});
              await pumpAt(tester, const Size(1440, 1000), const ClientDetailScreen(clientId: 1));

              expect(find.text('Solo Nombre'), findsOneWidget);
              expect(find.text('Sin datos de contacto ni ubicación.'), findsOneWidget);
              expect(find.text('Ubicación'), findsNothing);
              expect(find.text('Contactos (0)'), findsOneWidget);
              expect(find.text('Este cliente no tiene contactos.'), findsOneWidget);
              expect(find.text('No tienes actividades con este cliente.'), findsOneWidget);
              expect(find.byKey(const Key('activities-meta')), findsNothing);
              expect(find.text('No has registrado ventas a este cliente.'), findsOneWidget);
              expect(find.text('Productos tratados en tus actividades'), findsNothing);
              expect(find.textContaining('Ver todas'), findsNothing);
            }));

    testWidgets('móvil: «Atrás» en la cabecera del shell, sin duplicar la vuelta en el contenido',
        (tester) => backend.run(() async {
              stubDetail();
              await pumpAt(tester, const Size(390, 844), const ClientDetailScreen(clientId: 1));
              expect(find.byType(BackButton), findsOneWidget);
              expect(find.byTooltip('Abrir menú'), findsNothing);
              expect(find.widgetWithText(TextButton, 'Clientes'), findsNothing);
              // Una sola columna: Contactos debajo de Información
              expect(top(tester, 'Contactos (1)'), greaterThan(top(tester, 'Información')));
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
            stubDetail(activities: manyActivities(7));
            await pumpAt(tester, size, const ClientDetailScreen(clientId: 1));
            expect(tester.takeException(), isNull);

            if (size.width >= 1100) {
              // Contenido con el mismo ancho máximo que Inicio y Clientes
              expect(tester.getSize(find.byType(CvListSurface).first).width, lessThanOrEqualTo(1080));
            }
            if (size.width < 1100 && size.width >= 800) {
              // Tablet: una columna (Contactos bajo Información)
              expect(top(tester, 'Contactos (1)'), greaterThan(top(tester, 'Información')));
            }
            await tester.scrollUntilVisible(find.text('Monitor Vela 24 × 3'), 300,
                scrollable: find.descendant(of: find.byType(CvPageBody), matching: find.byType(Scrollable)).first);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }));
    });
  });
}
