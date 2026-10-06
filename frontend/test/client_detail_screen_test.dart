// H.3 · Ficha de cliente: secciones, contactos (alta/edición), actividades
// con estado, ventas (alta multilínea, edición y borrado) y resumen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/crm.dart';
import 'package:frontend/screens/client_detail_screen.dart';
import 'package:frontend/widgets/crm/sale_form.dart';

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
            expect(find.text('Tus actividades (1)'), findsOneWidget);
            expect(find.text('Pendiente · vencida'), findsOneWidget);
            expect(find.text('Presentar el monitor'), findsOneWidget);
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
}
