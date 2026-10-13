// H.3 · Smoke de anchura de móvil (360 px): pantallas y formularios del CRM
// sin desbordamientos (un overflow hace fallar el test) y formularios a
// pantalla completa con el botón de guardar accesible.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/calendar_screen.dart';
import 'package:frontend/screens/client_detail_screen.dart';
import 'package:frontend/screens/clients_screen.dart';
import 'package:frontend/screens/history_screen.dart';

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
        {"id": 1, "name": "Nebula Logística Integral de Transportes del Mediterráneo S.L.", "alias": "Nebula", "city": "Madrid"}
      ]
    });
    backend.json('GET', '/clients/1', clientDetailJson());
    backend.json('GET', '/activities', {"activities": [listedActivity(at: yesterday)]});
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpPhone(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, screen));
    await tester.pumpAndSettle();
  }

  testWidgets('Clientes en móvil', (tester) => backend.run(() async {
        await pumpPhone(tester, const ClientsScreen());
        expect(find.text('Nuevo cliente'), findsOneWidget);
        await tapText(tester, 'Nuevo cliente');
        // Formulario a pantalla completa con la acción abajo
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.text('Crear cliente'), findsOneWidget);
      }));

  testWidgets('Ficha y formularios de contacto, actividad y venta en móvil', (tester) => backend.run(() async {
        await pumpPhone(tester, const ClientDetailScreen(clientId: 1));
        expect(find.text('Ventas'), findsOneWidget);

        await tapText(tester, 'Nueva');
        expect(find.text('Crear actividad'), findsOneWidget);
        await tester.tap(find.byTooltip('Cerrar'));
        await tester.pumpAndSettle();

        await tapText(tester, 'Registrar venta');
        await tapText(tester, 'Añadir línea');
        expect(find.text('Guardar venta'), findsOneWidget);
        await tester.tap(find.byTooltip('Cerrar'));
        await tester.pumpAndSettle();

        await tapText(tester, 'Añadir');
        expect(find.text('Crear contacto'), findsOneWidget);
      }));

  testWidgets('Actividades en móvil', (tester) => backend.run(() async {
        await pumpPhone(tester, const HistoryScreen());
        expect(find.text('Nueva actividad'), findsOneWidget);
        expect(find.text('Pendiente · vencida'), findsOneWidget);
      }));

  testWidgets('Calendario en móvil', (tester) => backend.run(() async {
        await pumpPhone(tester, const CalendarScreen());
        expect(find.text('Nueva actividad'), findsOneWidget);
      }));
}
