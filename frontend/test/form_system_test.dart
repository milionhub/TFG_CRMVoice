// I.6.2 · Sistema de formularios: contenedor común (diálogo en escritorio,
// pantalla completa o panel inferior en móvil), tema CRMVoice de los campos,
// secciones, etiquetas de producto, pie de acciones, filtros de Actividades
// y selector con búsqueda. La lógica de cada formulario se prueba en sus
// propios tests; aquí, la presentación común y el responsive.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/design/cv_tokens.dart';
import 'package:frontend/screens/client_detail_screen.dart';
import 'package:frontend/screens/clients_screen.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:frontend/widgets/crm/activity_form.dart';
import 'package:frontend/widgets/crm/form_shell.dart';
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
    backend.json('GET', '/clients', {
      "clients": [
        {"id": 1, "name": "Nebula Logística S.L."},
        {"id": 2, "name": "Orión Servicios"},
      ]
    });
    backend.json('GET', '/clients/1', clientDetailJson());
    backend.json('GET', '/activities', {"activities": [listedActivity(at: yesterday)]});
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pump(WidgetTester tester, Widget screen, {Size? size}) async {
    if (size == null) {
      useDesktopSurface(tester);
    } else {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, screen));
    await tester.pumpAndSettle();
  }

  group('escritorio', () {
    testWidgets('Nueva actividad: diálogo con cabecera, secciones, tema CRMVoice y pie unificado',
        (tester) => backend.run(() async {
              await pump(tester, const ClientDetailScreen(clientId: 1));
              await tapText(tester, 'Nueva');

              expect(find.byType(Dialog), findsOneWidget);
              expect(find.byType(AppBar), findsNothing);
              expect(find.byTooltip('Cerrar'), findsOneWidget);
              final panel = tester.getSize(find.ancestor(of: find.text('Nueva actividad'), matching: find.byType(ClipRRect)).first);
              expect(panel.width, lessThanOrEqualTo(640));

              for (final section in ['Cliente y contacto', 'Actividad', 'Estado', 'Productos']) {
                expect(find.descendant(of: find.byType(FormSection), matching: find.text(section)), findsOneWidget,
                    reason: section);
              }
              // Cliente fijo de la ficha: valor de contexto, no un campo desactivado
              expect(find.byType(ReadOnlyField), findsOneWidget);

              // Pie: secundaria + principal del sistema Cv; sin «Eliminar» al crear
              expect(find.widgetWithText(CvSecondaryButton, 'Cancelar'), findsOneWidget);
              expect(find.widgetWithText(CvPrimaryButton, 'Crear actividad'), findsOneWidget);
              expect(find.byType(FormDeleteButton), findsNothing);

              // Los campos heredan el tema de formulario (foco en primaryDark)
              final theme = Theme.of(tester.element(find.byKey(const Key('activity-type-field'))));
              expect((theme.inputDecorationTheme.focusedBorder as OutlineInputBorder).borderSide.color,
                  CvColors.primaryDark);
              expect(theme.colorScheme.primary, CvColors.primaryDark);

              // Validación: errores de campo integrados, sin enviar
              await tapText(tester, 'Crear actividad');
              expect(find.text('Selecciona el tipo de actividad'), findsOneWidget);
              expect(backend.calls('POST', '/activities'), isEmpty);
            }));

    testWidgets('Editar actividad: productos como etiquetas que se quitan y «Eliminar» separado a la izquierda',
        (tester) => backend.run(() async {
              await pump(tester, const ClientDetailScreen(clientId: 1));
              await tester.tap(find.text('Concertar reunión').first);
              await tester.pumpAndSettle();
              expect(find.text('Editar actividad'), findsOneWidget);

              expect(find.byType(FormTag), findsOneWidget);
              expect(find.descendant(of: find.byType(FormTag), matching: find.text('Monitor Vela 24')), findsOneWidget);

              final delete = tester.getRect(find.byType(FormDeleteButton));
              final save = tester.getRect(find.widgetWithText(CvPrimaryButton, 'Guardar cambios'));
              expect(delete.right, lessThan(save.left - 100), reason: 'separado del botón principal');

              await tester.tap(find.byTooltip('Quitar Monitor Vela 24'));
              await tester.pumpAndSettle();
              expect(find.byType(FormTag), findsNothing);
              expect(find.text('Sin productos'), findsOneWidget);
            }));

    testWidgets('Registrar venta: líneas sin tarjetas, añadir/quitar y total con presencia',
        (tester) => backend.run(() async {
              await pump(tester, const ClientDetailScreen(clientId: 1));
              await tapText(tester, 'Registrar venta');

              expect(find.text('Líneas de venta'), findsOneWidget);
              expect(find.text('Línea 1'), findsOneWidget);
              await tester.enterText(find.widgetWithText(TextFormField, 'Importe total *'), '1500');
              await tester.pump();
              expect(tester.widget<Text>(find.byKey(const Key('sale-total'))).data, '1.500,00 €');

              await tapText(tester, 'Añadir línea');
              expect(find.text('Línea 2'), findsOneWidget);
              expect(tester.widget<Text>(find.byKey(const Key('sale-total'))).data, '—'); // falta el importe
              await tester.tap(find.byTooltip('Quitar línea').last);
              await tester.pumpAndSettle();
              expect(find.text('Línea 2'), findsNothing);
              expect(tester.widget<Text>(find.byKey(const Key('sale-total'))).data, '1.500,00 €');

              // Cantidad e importe en fila en escritorio
              final quantity = tester.getRect(find.widgetWithText(TextFormField, 'Cantidad'));
              final amount = tester.getRect(find.widgetWithText(TextFormField, 'Importe total *'));
              expect(amount.left, greaterThan(quantity.right));
            }));

    testWidgets('Nuevo cliente y nuevo contacto: secciones y valor de contexto de solo lectura',
        (tester) => backend.run(() async {
              await pump(tester, const ClientsScreen());
              await tapText(tester, 'Nuevo cliente');
              for (final section in ['Datos principales', 'Ubicación', 'Contacto', 'Información fiscal']) {
                expect(find.text(section), findsOneWidget, reason: section);
              }
              // Población y provincia en fila en escritorio
              final city = tester.getRect(find.widgetWithText(TextFormField, 'Población'));
              final province = tester.getRect(find.widgetWithText(TextFormField, 'Provincia'));
              expect(province.left, greaterThan(city.right));
              await tester.tap(find.byTooltip('Cerrar'));
              await tester.pumpAndSettle();
            }));

    testWidgets('Contacto: cliente fijo como valor de contexto', (tester) => backend.run(() async {
          final semantics = tester.ensureSemantics();
          await pump(tester, const ClientDetailScreen(clientId: 1));
          await tapText(tester, 'Añadir');

          expect(find.text('Datos del contacto'), findsOneWidget);
          expect(find.bySemanticsLabel('Cliente: Nebula Logística S.L. (no se cambia aquí)'), findsOneWidget);
          semantics.dispose();
        }));

    testWidgets('Filtros: diálogo compacto (no panel inferior) con «Limpiar» y «Aplicar filtros»',
        (tester) => backend.run(() async {
              await pump(tester, const HistoryScreen());
              await tapText(tester, 'Filtros');

              expect(find.text('Filtrar actividades'), findsOneWidget);
              expect(find.byType(Dialog), findsOneWidget);
              expect(find.byType(BottomSheet), findsNothing);
              expect(find.text('Limpiar'), findsOneWidget);
              expect(find.widgetWithText(CvPrimaryButton, 'Aplicar filtros'), findsOneWidget);
              expect(find.text('Cualquier fecha'), findsOneWidget);
              final panel = find.ancestor(of: find.text('Filtrar actividades'), matching: find.byType(ClipRRect)).first;
              expect(tester.getSize(panel).width, lessThanOrEqualTo(520));
            }));

    testWidgets('Selector con búsqueda: mismo sistema, búsqueda protagonista, sin resultados y selección',
        (tester) => backend.run(() async {
              await pump(tester, const HistoryScreen());
              await tapText(tester, 'Nueva actividad');
              await tester.tap(find.byKey(const Key('activity-client-field')));
              await tester.pumpAndSettle();

              expect(find.text('Seleccionar cliente'), findsNWidgets(2)); // título del selector y campo vacío
              expect(find.byType(CvSearchField), findsOneWidget);
              expect(find.text('Resultados'), findsOneWidget);
              expect(find.text('Orión Servicios'), findsOneWidget);

              await tester.enterText(find.widgetWithText(TextField, 'Buscar cliente...'), 'zzz');
              await tester.pump();
              expect(find.text('Sin resultados'), findsOneWidget);

              await tester.enterText(find.widgetWithText(TextField, 'Buscar cliente...'), 'orion');
              await tester.pump();
              expect(find.text('1 resultado'), findsOneWidget);
              await tapText(tester, 'Orión Servicios');
              expect(find.text('Seleccionar cliente'), findsNothing);
              expect(find.descendant(of: find.byType(ActivityForm), matching: find.text('Orión Servicios')),
                  findsOneWidget);
            }));
  });

  group('móvil', () {
    for (final width in [390.0, 360.0]) {
      testWidgets('${width.toInt()} px: Nueva actividad y Registrar venta a pantalla completa, sin desbordes',
          (tester) => backend.run(() async {
                await pump(tester, const ClientDetailScreen(clientId: 1), size: Size(width, 800));

                // Un overflow haría fallar el test
                await tapText(tester, 'Nueva');
                expect(find.byType(AppBar), findsOneWidget);
                expect(find.byType(Dialog), findsNothing);
                expect(tester.getRect(find.widgetWithText(CvPrimaryButton, 'Crear actividad')).right,
                    lessThanOrEqualTo(width));
                await tester.tap(find.byTooltip('Cerrar'));
                await tester.pumpAndSettle();

                await tapText(tester, 'Registrar venta');
                await tapText(tester, 'Añadir línea');
                expect(find.text('Línea 2'), findsOneWidget);
                // Cantidad e importe se apilan en vez de comprimirse
                final quantity = tester.getRect(find.widgetWithText(TextFormField, 'Cantidad').first);
                final amount = tester.getRect(find.widgetWithText(TextFormField, 'Importe total *').first);
                expect(amount.top, greaterThan(quantity.bottom));
                expect(tester.getRect(find.widgetWithText(CvPrimaryButton, 'Guardar venta')).right,
                    lessThanOrEqualTo(width));
              }));

      testWidgets('${width.toInt()} px: filtros en panel inferior y selector con búsqueda a pantalla completa',
          (tester) => backend.run(() async {
                await pump(tester, const HistoryScreen(), size: Size(width, 800));

                await tapText(tester, 'Filtros');
                expect(find.byType(BottomSheet), findsOneWidget);
                expect(find.text('Filtrar actividades'), findsOneWidget);
                await tester.ensureVisible(find.text('Aplicar filtros'));
                expect(tester.getRect(find.text('Aplicar filtros')).right, lessThanOrEqualTo(width));
                await tester.tap(find.byTooltip('Cerrar'));
                await tester.pumpAndSettle();
                expect(find.byType(BottomSheet), findsNothing);

                await tapText(tester, 'Nueva actividad');
                await tester.tap(find.byKey(const Key('activity-client-field')));
                await tester.pumpAndSettle();
                final picker = tester.getRect(find.ancestor(of: find.byType(CvSearchField), matching: find.byType(Dialog)));
                expect(picker.width, width, reason: 'pantalla completa en móvil');
                expect(find.text('Nebula Logística S.L.'), findsOneWidget);
              }));
    }
  });
}
