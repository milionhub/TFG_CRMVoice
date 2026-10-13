// Actividades (antes Histórico; HistoryScreen): carga, lista compacta, vacío,
// filtros, acciones del menú «⋮», borrado, error (FE-D7-01) y responsive.
// I.4.1: la fila muestra los productos asociados, no el comentario.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:frontend/widgets/crm/activity_list.dart';
import 'package:frontend/widgets/crm/crm_ui.dart';
import 'package:frontend/widgets/shell/app_shell.dart';
import 'package:http/http.dart' as http;

import 'support/crm_fixtures.dart';
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
  "status": "completed",
  "products": [
    {"product_id": 4, "product_raw": "Monitor Vela 24"},
  ],
};

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

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

  Future<void> pumpHistory(WidgetTester tester, {Size? size}) async {
    if (size == null) {
      useDesktopSurface(tester);
    } else {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const HistoryScreen()));
  }

  testWidgets('cabecera y shell: «Actividades» con subtítulo, destino activo y acción principal',
      (tester) => backend.run(() async {
            backend.json('GET', '/activities', {"activities": [activity]});
            await pumpHistory(tester);
            await tester.pumpAndSettle();

            final sidebar = find.byType(Sidebar);
            expect(find.descendant(of: sidebar, matching: find.text('Actividades')), findsOneWidget);
            expect(find.descendant(of: sidebar, matching: find.text('Histórico')), findsNothing);
            expect(tester.widget<AppShell>(find.byType(AppShell)).currentIndex, 3);
            expect(shellDestinations[3].label, 'Actividades');

            expect(find.text('Actividades'), findsNWidgets(2)); // barra lateral y título
            expect(find.text('Histórico CRM'), findsNothing);
            expect(find.text('Gestiona y consulta toda tu actividad comercial.'), findsOneWidget);
            expect(find.text('Nueva actividad'), findsOneWidget);
            expect(find.byTooltip('Actualizar'), findsOneWidget);
            expect(find.text('Filtros'), findsOneWidget);
            for (final label in ['Todas', 'Pendientes', 'Completadas', 'Canceladas']) {
              expect(find.text(label), findsOneWidget, reason: label);
            }
          }));

  testWidgets('carga y después filas compactas: cliente, contacto, estado y productos; sin comentario',
      (tester) => backend.run(() async {
            final pending = Completer<http.Response>();
            backend.on('GET', '/activities', (_) => pending.future);
            await pumpHistory(tester);
            await tester.pump();

            expect(find.byType(CircularProgressIndicator), findsOneWidget);

            final bare = {...activity, "id": 3, "products": <Object>[]};
            pending.complete(_json({"count": 2, "activities": [activity, bare]}));
            await tester.pumpAndSettle();

            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(find.byType(ActivityListRow), findsNWidgets(2));
            expect(find.text('Concertar reunión'), findsNWidgets(2));
            expect(find.text('1 oct 2026 · 10:30'), findsNWidgets(2));
            expect(find.text('Nebula Logística S.L. · Nora Quintana', findRichText: true), findsNWidgets(2));
            expect(find.byType(StatusBadge), findsNWidgets(2));
            expect(find.text('Completada'), findsNWidgets(2));
            expect(find.text('2 actividades'), findsOneWidget);

            // Productos asociados visibles; el comentario solo al editar
            final withProducts = find.byKey(const ValueKey('activity-1'));
            final without = find.byKey(const ValueKey('activity-3'));
            expect(find.descendant(of: withProducts, matching: find.text('Monitor Vela 24')), findsOneWidget);
            expect(find.textContaining('Presentar el monitor'), findsNothing);

            // Sin productos no se reserva espacio
            expect(find.descendant(of: without, matching: find.byKey(const Key('activity-products'))), findsNothing);

            // Filas compactas: sin productos como antes; con productos crece poco
            final bareHeight = tester.getSize(without).height;
            final fullHeight = tester.getSize(withProducts).height;
            expect(bareHeight, lessThan(100));
            expect(fullHeight - bareHeight, inInclusiveRange(1, 30));
            expect(find.byTooltip('Acciones'), findsNWidgets(2));
            expect(find.byIcon(Icons.delete_outline), findsNothing);
            expect(find.byIcon(Icons.flag_outlined), findsNothing);
            expect(backend.calls('GET', '/activities').single.headers['Authorization'], startsWith('Bearer '));
          }));

  testWidgets('el menú «⋮» conserva editar, cambios de estado y eliminar', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"activities": [activity]});
        await pumpHistory(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Acciones'));
        await tester.pumpAndSettle();
        expect(find.text('Editar'), findsOneWidget);
        expect(find.text('Marcar pendiente'), findsOneWidget);
        expect(find.text('Cancelar actividad'), findsOneWidget);
        expect(find.text('Eliminar actividad'), findsOneWidget);
      }));

  testWidgets('sin actividades muestra el estado vacío', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"count": 0, "activities": []});
        await pumpHistory(tester);
        await tester.pumpAndSettle();

        expect(find.text('Aún no tienes actividades.'), findsOneWidget);
        expect(find.text('Quitar filtros'), findsNothing);
      }));

  testWidgets('filtro por estado sin resultados: vacío filtrado y «Quitar filtros» vuelve a Todas',
      (tester) => backend.run(() async {
            backend.on('GET', '/activities', (request) {
              final status = request.url.queryParameters['status'];
              return _json({"activities": status == null ? [activity] : []});
            });
            await pumpHistory(tester);
            await tester.pumpAndSettle();

            await tapText(tester, 'Canceladas');
            expect(backend.calls('GET', '/activities').last.url.queryParameters['status'], 'cancelled');
            expect(find.text('No hay actividades con estos filtros.'), findsOneWidget);

            await tapText(tester, 'Quitar filtros');
            expect(backend.calls('GET', '/activities').last.url.queryParameters.containsKey('status'), isFalse);
            expect(find.byType(ActivityListRow), findsOneWidget);
          }));

  testWidgets('filtros avanzados: el diálogo aplica la acción y el filtro activo se puede quitar',
      (tester) => backend.run(() async {
            backend.on('GET', '/activities', (_) => _json({"activities": [activity]}));
            await pumpHistory(tester);
            await tester.pumpAndSettle();
            expect(find.byType(ActiveFilterChip), findsNothing);

            await tapText(tester, 'Filtros');
            expect(find.text('Filtrar actividades'), findsOneWidget);
            await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, 'Acción'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Concertar reunión').last);
            await tester.pumpAndSettle();
            await tapText(tester, 'Aplicar filtros');

            expect(backend.calls('GET', '/activities').last.url.queryParameters['action_id'], '1');
            expect(find.text('Filtros (1)'), findsOneWidget);
            final chip = find.byType(ActiveFilterChip);
            expect(chip, findsOneWidget);
            expect(find.descendant(of: chip, matching: find.text('Concertar reunión')), findsOneWidget);

            await tester.tap(find.byTooltip('Quitar filtro'));
            await tester.pumpAndSettle();
            expect(find.byType(ActiveFilterChip), findsNothing);
            expect(find.text('Filtros'), findsOneWidget);
            expect(backend.calls('GET', '/activities').last.url.queryParameters.containsKey('action_id'), isFalse);
          }));

  testWidgets('borrar desde «⋮»: confirma, llama a DELETE y recarga la lista', (tester) => backend.run(() async {
        var listed = 0;
        backend.on('GET', '/activities', (_) {
          listed++;
          return _json({"activities": listed == 1 ? [activity] : []});
        });
        backend.json('DELETE', '/activities/1', {"success": true});
        await pumpHistory(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Acciones'));
        await tester.pumpAndSettle();
        await tapText(tester, 'Eliminar actividad');
        await tester.tap(find.text('Eliminar'));
        await tester.pumpAndSettle();

        expect(backend.calls('DELETE', '/activities/1'), hasLength(1));
        expect(listed, 2);
        expect(find.text('Aún no tienes actividades.'), findsOneWidget);
      }));

  testWidgets('borrar y cancelar: no llama a DELETE', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"activities": [activity]});
        await pumpHistory(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Acciones'));
        await tester.pumpAndSettle();
        await tapText(tester, 'Eliminar actividad');
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();

        expect(backend.calls('DELETE', '/activities/1'), isEmpty);
        expect(find.byType(ActivityListRow), findsOneWidget);
      }));

  testWidgets('FE-D7-01: si falla la carga no se queda cargando indefinidamente', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"detail": "error"}, status: 500);
        await pumpHistory(tester);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('No se pudieron cargar las actividades.'), findsOneWidget);
        expect(find.text('Reintentar'), findsOneWidget);
      })); // FE-D7-01 resuelto en H.3: estado de error con Reintentar

  for (final width in [390.0, 360.0]) {
    testWidgets('móvil ${width.toInt()} px: sin desbordes, estado bajo el título y «⋮» accesible',
        (tester) => backend.run(() async {
              final long = {
                ...activity,
                "id": 2,
                "accion": "Realizar llamada de seguimiento",
                "cliente": "Nebula Logística Integral de Transportes del Mediterráneo S.L.",
                "contacto": "Nora Quintana Fernández de Villaverde",
                "status": "pending",
                "fecha": "2020-01-01T09:00:00",
                "products": [
                  {"product_id": 4, "product_raw": "Monitor Vela 24"},
                  {"product_raw": "Teclado Nube inalámbrico"},
                  {"product_raw": "Soporte articulado doble para monitores de gran formato Serie Profesional"},
                  {"product_raw": "Ratón Brisa"},
                ],
              };
              backend.on('GET', '/activities', (_) => _json({"activities": [activity, long]}));
              await pumpHistory(tester, size: Size(width, 1000));
              await tester.pumpAndSettle();

              // Un overflow haría fallar el test
              expect(find.byType(ActivityListRow), findsNWidgets(2));
              expect(find.text('Pendiente · vencida'), findsOneWidget);
              expect(find.byTooltip('Actualizar'), findsNothing); // en móvil se desliza para recargar
              expect(find.text('Nueva actividad'), findsOneWidget);

              final row = tester.getRect(find.byKey(const ValueKey('activity-2')));
              final badge = tester.getRect(find.text('Pendiente · vencida'));
              final title = tester.getRect(find.text('Realizar llamada de seguimiento'));
              expect(badge.top, greaterThanOrEqualTo(title.bottom), reason: 'el estado no comprime el título');
              final menu = tester.getRect(find.byTooltip('Acciones').last);
              expect(menu.right, lessThanOrEqualTo(row.right));
              expect(menu.width, greaterThanOrEqualTo(40));

              // Productos: varios hacen wrap dentro de la fila, sin salirse
              final products = find.descendant(
                  of: find.byKey(const ValueKey('activity-2')), matching: find.byKey(const Key('activity-products')));
              final tags = find.descendant(of: products, matching: find.byType(Text));
              expect(tags, findsNWidgets(4));
              final tagRects = [for (var i = 0; i < 4; i++) tester.getRect(tags.at(i))];
              expect(tagRects.map((r) => r.top).toSet().length, greaterThan(1), reason: 'varias líneas');
              for (final r in tagRects) {
                expect(r.left, greaterThanOrEqualTo(row.left));
                expect(r.right, lessThanOrEqualTo(row.right));
              }

              // Los cuatro estados completos en una fila, sin scroll horizontal
              final selector = find.byType(ActivityStatusFilter);
              final selectorRect = tester.getRect(selector);
              expect(selectorRect.right, lessThanOrEqualTo(width));
              expect(find.ancestor(of: selector, matching: find.byType(SingleChildScrollView)), findsNothing);
              final labels = ['Todas', 'Pendientes', 'Completadas', 'Canceladas'];
              final rects = [for (final l in labels) tester.getRect(find.text(l))];
              for (var i = 0; i < rects.length; i++) {
                expect(rects[i].left, greaterThanOrEqualTo(selectorRect.left), reason: labels[i]);
                expect(rects[i].right, lessThanOrEqualTo(selectorRect.right), reason: labels[i]);
                expect(rects[i].center.dy, closeTo(rects[0].center.dy, 1), reason: 'una sola fila');
                if (i > 0) expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right), reason: labels[i]);
              }
              for (final l in labels) {
                expect(tester.getSize(find.ancestor(of: find.text(l), matching: find.byType(InkWell)).first).height,
                    greaterThanOrEqualTo(36), reason: '$l: objetivo táctil');
              }

              await tapText(tester, 'Canceladas');
              expect(backend.calls('GET', '/activities').last.url.queryParameters['status'], 'cancelled');
            }));
  }
}
