// I.8 · Productos: catálogo comercial (nombre y PVP, sin stock).
// Listado, búsqueda local, estados de carga/vacío/error, crear/editar con el
// Interaction System, eliminar con confirmación (y aviso si está en uso),
// responsive, navegación, una sola fuente de productos para actividades y
// ventas, y la revisión de las acciones de producto de Voice V2.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/crm.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/products_screen.dart';
import 'package:frontend/widgets/crm/activity_form.dart';
import 'package:frontend/widgets/crm/sale_form.dart';
import 'package:frontend/widgets/shell/app_shell.dart';
import 'package:http/http.dart' as http;

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';
import 'support/voice_fixtures.dart';

/// Catálogo en memoria: GET/POST/PUT/DELETE /products sobre la misma lista.
class FakeCatalog {
  final List<Map<String, dynamic>> products;
  int _next = 100;

  FakeCatalog([List<Map<String, dynamic>>? initial])
      : products = initial ??
            [
              {"id": 1, "name": "Portátil Luna 13", "price": 790.0},
              {"id": 2, "name": "Ratón Faro", "price": 22.0},
              {"id": 3, "name": "Teclado Nube", "price": 29.9},
            ];

  void install(FakeBackend backend) {
    backend.on('GET', '/products', (_) => jsonResponse({"products": products}));
    backend.on('POST', '/products', (request) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final product = {"id": _next++, "name": body["name"], "price": double.parse(body["price"].replaceAll(',', '.'))};
      products.add(product);
      return jsonResponse(product, status: 201);
    });
  }
}

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpProducts(WidgetTester tester, {bool mobile = false}) async {
    if (mobile) {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    } else {
      useDesktopSurface(tester);
    }
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const ProductsScreen()));
  }

  Future<void> openMenu(WidgetTester tester, int productId, String action) async {
    final menu = find.descendant(
        of: find.byKey(ValueKey('product-$productId')), matching: find.byTooltip('Acciones del producto'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(action).last);
    await tester.pumpAndSettle();
  }

  group('listado', () {
    testWidgets('carga y muestra nombre y PVP, con contador', (tester) => backend.run(() async {
          final pending = Completer<http.Response>();
          backend.on('GET', '/products', (_) => pending.future);
          await pumpProducts(tester);
          await tester.pump();
          expect(find.text('Cargando productos…'), findsOneWidget);

          pending.complete(jsonResponse({"products": FakeCatalog().products}));
          await tester.pumpAndSettle();

          expect(find.text('Gestiona el catálogo comercial de tu CRM.'), findsOneWidget);
          expect(find.text('Portátil Luna 13'), findsOneWidget);
          expect(find.text('790,00 €'), findsOneWidget);
          expect(find.text('29,90 €'), findsOneWidget);
          expect(find.byKey(const Key('products-count')), findsOneWidget);
          expect(find.text('3 productos'), findsOneWidget);
          expect(find.textContaining('stock', findRichText: true), findsNothing);
          expect(find.textContaining('Stock'), findsNothing);
        }));

    testWidgets('búsqueda sin mayúsculas ni tildes y estado sin resultados', (tester) => backend.run(() async {
          FakeCatalog().install(backend);
          await pumpProducts(tester);
          await tester.pumpAndSettle();

          await tester.enterText(find.widgetWithText(TextField, 'Buscar producto por nombre'), 'raton');
          await tester.pumpAndSettle();
          expect(find.text('Ratón Faro'), findsOneWidget);
          expect(find.text('Portátil Luna 13'), findsNothing);
          expect(find.text('1 producto encontrado'), findsOneWidget);

          await tester.enterText(find.widgetWithText(TextField, 'Buscar producto por nombre'), 'webcam');
          await tester.pumpAndSettle();
          expect(find.text('No encontramos productos para esta búsqueda.'), findsOneWidget);
          await tapText(tester, 'Limpiar búsqueda');
          expect(find.text('3 productos'), findsOneWidget);
          expect(backend.calls('GET', '/products'), hasLength(1)); // búsqueda local, sin más peticiones
        }));

    testWidgets('catálogo vacío', (tester) => backend.run(() async {
          FakeCatalog([]).install(backend);
          await pumpProducts(tester);
          await tester.pumpAndSettle();
          expect(find.text('Tu catálogo está vacío.'), findsOneWidget);
          expect(find.text('Crear el primero'), findsOneWidget);
        }));

    testWidgets('error de carga y reintento', (tester) => backend.run(() async {
          var fail = true;
          backend.on('GET', '/products', (_) => fail
              ? jsonResponse({"detail": "Error interno"}, status: 500)
              : jsonResponse({"products": FakeCatalog().products}));
          await pumpProducts(tester);
          await tester.pumpAndSettle();
          expect(find.text('No se pudieron cargar los productos.'), findsOneWidget);

          fail = false;
          await tapText(tester, 'Reintentar');
          expect(find.text('Ratón Faro'), findsOneWidget);
        }));

    testWidgets('móvil (360 px): PVP bajo el nombre y sin desbordes', (tester) => backend.run(() async {
          FakeCatalog().install(backend);
          await pumpProducts(tester, mobile: true);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.widgetWithText(AppBar, 'Productos'), findsOneWidget);
          final name = tester.getRect(find.text('Ratón Faro'));
          final price = tester.getRect(find.byKey(const ValueKey('product-price-2')));
          expect(price.top, greaterThan(name.top));
          expect(find.text('PVP'), findsNothing); // la columna PVP es solo de escritorio
          expect(find.byTooltip('Acciones del producto'), findsNWidgets(3));
        }));
  });

  group('crear, editar y eliminar', () {
    testWidgets('nuevo producto: validaciones y POST con nombre y PVP; aparece en el listado',
        (tester) => backend.run(() async {
              FakeCatalog().install(backend);
              await pumpProducts(tester);
              await tester.pumpAndSettle();

              await tapText(tester, 'Nuevo producto');
              expect(find.text('Nuevo producto'), findsWidgets);
              await tester.enterText(find.byKey(const Key('product-price')), '89');
              await tester.pump();
              expect(find.text('= 89,00 €'), findsOneWidget); // interpretación visible antes de guardar
              await tester.enterText(find.byKey(const Key('product-price')), '');
              await tapText(tester, 'Crear producto');
              expect(find.text('El nombre es obligatorio'), findsOneWidget);
              expect(find.text('Indica el PVP'), findsOneWidget);
              expect(backend.calls('POST', '/products'), isEmpty);

              await tester.enterText(find.byKey(const Key('product-name')), 'Auriculares Nova');
              await tester.enterText(find.byKey(const Key('product-price')), '4,500');
              await tapText(tester, 'Crear producto');
              expect(find.textContaining('ambiguo'), findsOneWidget);

              await tester.enterText(find.byKey(const Key('product-price')), '89');
              await tapText(tester, 'Crear producto');

              expect(lastJson(backend, 'POST', '/products'), {"name": "Auriculares Nova", "price": "89"});
              expect(find.text('Auriculares Nova'), findsOneWidget);
              expect(find.text('4 productos'), findsOneWidget);
            }));

    testWidgets('duplicado: el formulario sigue abierto con el error del servidor', (tester) => backend.run(() async {
          FakeCatalog().install(backend);
          backend.json('POST', '/products', {
            "detail": "Ya existe el producto «Ratón Faro».",
            "code": "duplicate_name",
            "existing_id": 2,
            "issues": [
              {"code": "duplicate", "field": "name", "message": "Ya existe el producto «Ratón Faro».", "blocking": true}
            ]
          }, status: 409);
          await pumpProducts(tester);
          await tester.pumpAndSettle();
          await tapText(tester, 'Nuevo producto');
          await tester.enterText(find.byKey(const Key('product-name')), 'raton faro');
          await tester.enterText(find.byKey(const Key('product-price')), '22');
          await tapText(tester, 'Crear producto');

          expect(find.textContaining('Ya existe el producto «Ratón Faro».'), findsWidgets);
          expect(find.text('Crear producto'), findsOneWidget);
        }));

    testWidgets('editar desde el menú «⋮»: datos actuales y PUT', (tester) => backend.run(() async {
          final catalog = FakeCatalog()..install(backend);
          backend.on('PUT', '/products/3', (request) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            catalog.products[2] = {"id": 3, "name": body["name"], "price": 34.5};
            return jsonResponse(catalog.products[2]);
          });
          await pumpProducts(tester);
          await tester.pumpAndSettle();

          await openMenu(tester, 3, 'Editar producto');
          expect(find.text('Editar producto'), findsWidgets);
          expect(tester.widget<TextFormField>(find.byKey(const Key('product-price'))).controller!.text, '29,90');
          await tester.enterText(find.byKey(const Key('product-price')), '34,50');
          await tapText(tester, 'Guardar cambios');

          expect(lastJson(backend, 'PUT', '/products/3'), {"name": "Teclado Nube", "price": "34,50"});
          expect(find.text('34,50 €'), findsOneWidget);
        }));

    testWidgets('eliminar: diálogo de confirmación CRMVoice; cancelar no borra', (tester) => backend.run(() async {
          final catalog = FakeCatalog()..install(backend);
          backend.on('DELETE', '/products/3', (_) {
            catalog.products.removeWhere((p) => p["id"] == 3);
            return http.Response('', 204);
          });
          await pumpProducts(tester);
          await tester.pumpAndSettle();

          await openMenu(tester, 3, 'Eliminar producto');
          expect(find.textContaining('¿Seguro que quieres eliminar «Teclado Nube»'), findsOneWidget);
          await tapText(tester, 'Cancelar');
          expect(backend.calls('DELETE', '/products/3'), isEmpty);

          await openMenu(tester, 3, 'Eliminar producto');
          await tapText(tester, 'Eliminar');
          expect(backend.calls('DELETE', '/products/3'), hasLength(1));
          expect(find.text('Teclado Nube'), findsNothing);
          expect(find.text('2 productos'), findsOneWidget);
        }));

    testWidgets('eliminar un producto en uso: aviso y se conserva', (tester) => backend.run(() async {
          FakeCatalog().install(backend);
          backend.json('DELETE', '/products/1', {
            "detail": "No se puede eliminar: el producto aparece en 2 actividades, 1 ventas. Así se conserva el histórico.",
            "code": "product_in_use"
          }, status: 409);
          await pumpProducts(tester);
          await tester.pumpAndSettle();

          await openMenu(tester, 1, 'Eliminar producto');
          await tapText(tester, 'Eliminar');
          expect(find.text('No se puede eliminar'), findsOneWidget);
          expect(find.textContaining('Así se conserva el histórico'), findsOneWidget);
          await tapText(tester, 'Entendido');
          expect(find.text('Portátil Luna 13'), findsOneWidget);
        }));
  });

  group('navegación y fuente única', () {
    testWidgets('«Productos» va entre Actividades y Chat IA y abre la pantalla', (tester) => backend.run(() async {
          expect(shellDestinations.map((d) => d.label).toList(),
              ['Inicio', 'Clientes', 'Calendario', 'Actividades', 'Productos', 'Chat IA']);
          FakeCatalog().install(backend);
          useDesktopSurface(tester);
          final auth = await loggedInAuth(backend);
          await tester.pumpWidget(appFor(auth, const ProductsScreen()));
          await tester.pumpAndSettle();
          final sidebarItem = find.descendant(of: find.byType(Sidebar), matching: find.text('Productos'));
          expect(sidebarItem, findsOneWidget);
          expect(find.byType(ProductsScreen), findsOneWidget);
          expect(find.byType(HomeScreen), findsNothing);
        }));

    testWidgets('un producto creado aparece en Nueva actividad (misma lista GET /products)',
        (tester) => backend.run(() async {
              stubCatalogs(backend);
              final catalog = FakeCatalog()..install(backend);
              catalog.products.add({"id": 50, "name": "Auriculares Nova", "price": 89.0});
              backend.json('GET', '/clients', {"clients": [{"id": 1, "name": "Nebula Logística S.L."}]});
              useDesktopSurface(tester);
              final auth = await loggedInAuth(backend);
              await tester.pumpWidget(appFor(auth, hostWith((context) => openActivityForm(context))));
              await tapText(tester, 'abrir');

              await tapText(tester, 'Añadir producto');
              expect(find.text('Auriculares Nova'), findsOneWidget);
            }));

    testWidgets('un producto creado aparece en Registrar venta (misma lista GET /products)',
        (tester) => backend.run(() async {
              final catalog = FakeCatalog()..install(backend);
              catalog.products.add({"id": 50, "name": "Auriculares Nova", "price": 89.0});
              useDesktopSurface(tester);
              final auth = await loggedInAuth(backend);
              final client = Client.fromJson(nebulaClient);
              await tester.pumpWidget(appFor(auth,
                  hostWith((context) => openSaleForm(context, client: client, contacts: [Contact.fromJson(noraContact)!]))));
              await tapText(tester, 'abrir');

              await tester.tap(find.byTooltip('Elegir producto del catálogo').first);
              await tester.pumpAndSettle();
              expect(find.text('Auriculares Nova'), findsOneWidget);
            }));
  });

  group('revisión de Voice V2', () {
    late ReviewHost host;

    setUp(() => host = ReviewHost());

    Future<void> pumpReview(WidgetTester tester, Map<String, dynamic> draft) async {
      useDesktopSurface(tester);
      final auth = await loggedInAuth(backend);
      await tester.pumpWidget(appFor(auth, host.build(draft)));
      await tapText(tester, 'abrir');
    }

    bool confirmEnabled(WidgetTester tester) => tester
        .widget<ButtonStyleButton>(find.descendant(
            of: find.byKey(const Key('voice-confirm')), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)))
        .enabled;

    Map<String, dynamic> newProduct({int? priceCents = 8900, List<Map<String, dynamic>> issues = const []}) =>
        draftJson(
          id: 'drf_prod',
          type: 'create_product',
          sourceText: 'Crea un producto llamado Auriculares Nova con un PVP de 89 euros.',
          fields: {"name": "Auriculares Nova", "price_cents": priceCents, "price_said": priceCents == null ? null : "89.00",
                   "price_error": null},
          issues: issues,
        );

    testWidgets('Nuevo producto: nombre y PVP; confirmar envía solo la revisión', (tester) => backend.run(() async {
          backend.json('POST', '/actions/drf_prod/confirm', {
            "result": {"entity": "product", "ids": [50], "data": {"id": 50, "name": "Auriculares Nova", "price": 89.0}},
            "draft": {...newProduct(), "status": "executed", "confirmable": false},
          });
          await pumpReview(tester, newProduct());

          expect(find.text('Nuevo producto'), findsOneWidget);
          expect(find.text('Auriculares Nova'), findsOneWidget);
          expect(find.text('89,00 €'), findsOneWidget);
          expect(find.text('PVP'), findsOneWidget);
          expect(find.textContaining('tock'), findsNothing);
          expect(confirmEnabled(tester), isTrue);

          await tester.ensureVisible(find.byKey(const Key('voice-confirm')));
          await tester.tap(find.byKey(const Key('voice-confirm')));
          await tester.pumpAndSettle();
          expect(lastJson(backend, 'POST', '/actions/drf_prod/confirm'), {"revision": 1});
          expect(find.text('Producto creado'), findsOneWidget);
        }));

    testWidgets('Nuevo producto sin PVP: bloquea; corregir el PVP -> PATCH', (tester) => backend.run(() async {
          backend.json('PATCH', '/actions/drf_prod', {...newProduct(), "revision": 2});
          await pumpReview(tester, newProduct(priceCents: null, issues: [
            issueJson('missing', 'price', 'Falta el PVP del producto.'),
          ]));

          expect(find.textContaining('Falta el PVP del producto.'), findsWidgets);
          expect(confirmEnabled(tester), isFalse);

          await tester.tap(find.byTooltip('Cambiar pvp'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).last, '89');
          await tapText(tester, 'Aplicar');
          expect(lastJson(backend, 'PATCH', '/actions/drf_prod'), {"revision": 1, "edits": {"price": "89"}});
          expect(confirmEnabled(tester), isTrue);
        }));

    Map<String, dynamic> change({Map<String, dynamic>? product, List<Map<String, dynamic>> issues = const []}) =>
        draftJson(
          id: 'drf_upd',
          type: 'update_product',
          sourceText: 'Cambia el precio de Auriculares Nova a 79 euros.',
          fields: {
            "product": product ??
                {"id": 50, "label": "Auriculares Nova", "said": "Auriculares Nova", "match": "exact", "problem": null,
                 "candidates": []},
            "name": null,
            "price_cents": 7900,
            "price_said": "79.00",
            "price_error": null,
            "current_name": product == null ? "Auriculares Nova" : null,
            "current_price_cents": product == null ? 8900 : null,
          },
          issues: issues,
        );

    testWidgets('Cambio de producto: solo lo que cambia, como antes → después', (tester) => backend.run(() async {
          await pumpReview(tester, change());
          expect(find.text('Cambio de producto'), findsOneWidget);
          expect(find.text('89,00 € → 79,00 €'), findsOneWidget);
          expect(find.text('Sin cambios (Auriculares Nova)'), findsOneWidget);
          expect(find.text('Coincidencia exacta'), findsOneWidget);
          expect(confirmEnabled(tester), isTrue);
        }));

    testWidgets('Cambio de producto ambiguo: candidatos; elegir uno -> PATCH product_id', (tester) => backend.run(() async {
          backend.json('PATCH', '/actions/drf_upd', change());
          await pumpReview(
              tester,
              change(product: {
                "id": null,
                "label": null,
                "said": "Auriculares",
                "match": null,
                "problem": "ambiguous",
                "candidates": [
                  {"id": 50, "label": "Auriculares Nova"},
                  {"id": 51, "label": "Auriculares Nova Pro"}
                ]
              }, issues: [
                issueJson('ambiguous', 'product', 'Hay varios productos que encajan con «Auriculares»: elige uno.',
                    candidates: [
                      {"id": 50, "label": "Auriculares Nova"},
                      {"id": 51, "label": "Auriculares Nova Pro"}
                    ])
              ]));
          expect(find.text('Varias coincidencias'), findsOneWidget);
          expect(confirmEnabled(tester), isFalse);

          await tapText(tester, 'Auriculares Nova Pro');
          expect(lastJson(backend, 'PATCH', '/actions/drf_upd'), {"revision": 1, "edits": {"product_id": 51}});
          expect(confirmEnabled(tester), isTrue);
        }));
  });
}
