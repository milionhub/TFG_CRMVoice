// H.5.2 (C) · Navegación móvil con el menú lateral: Inicio vuelve de verdad a
// Home, cada sección sustituye la pila (no se acumulan rutas), elegir la
// sección actual solo cierra el menú y una pantalla CRM reabierta carga datos
// actuales.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/calendar_screen.dart';
import 'package:frontend/screens/chat_screen.dart';
import 'package:frontend/screens/clients_screen.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:frontend/screens/home_screen.dart';

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';

void main() {
  late FakeBackend backend;
  var clientName = 'Nebula Logística S.L.';

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    clientName = 'Nebula Logística S.L.';
    FakeRecorderPlatform(Directory.systemTemp).install(); // micrófono de Home
    backend.json('GET', '/ping', {"status": "ok"});
    backend.on('GET', '/clients', (_) => jsonResponse({
          "clients": [
            {"id": 1, "name": clientName}
          ]
        }));
    backend.json('GET', '/activities', {"activities": []});
    backend.json('GET', '/activity-types', {"activity_types": []});
    backend.json('GET', '/products', {"products": []});
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpPhoneHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const HomeScreen()));
    await tester.pumpAndSettle();
  }

  Future<void> openSection(WidgetTester tester, String label) async {
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  /// Número de rutas de página en la pila (sin contar el menú, ya cerrado).
  bool canGoBack(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator).first).canPop();

  testWidgets('cada sección sustituye la pila y el menú se cierra', (tester) => backend.run(() async {
        await pumpPhoneHome(tester);

        for (final (label, type) in [
          ('Clientes', ClientsScreen),
          ('Calendario', CalendarScreen),
          ('Histórico', HistoryScreen),
          ('Chat IA', ChatScreen),
        ]) {
          await openSection(tester, label);
          expect(find.byType(type), findsOneWidget, reason: label);
          expect(find.byType(HomeScreen), findsNothing, reason: label);
          expect(find.byType(Drawer), findsNothing, reason: '$label: el menú queda cerrado');
          expect(canGoBack(tester), isFalse, reason: '$label: una sola ruta en la pila');
        }
      }));

  testWidgets('Inicio vuelve realmente a Home desde otra sección', (tester) => backend.run(() async {
        await pumpPhoneHome(tester);
        await openSection(tester, 'Histórico');
        expect(find.byType(HistoryScreen), findsOneWidget);

        await openSection(tester, 'Inicio');
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byType(HistoryScreen), findsNothing);
        expect(canGoBack(tester), isFalse);
      }));

  testWidgets('uso repetido del menú: la pila no crece', (tester) => backend.run(() async {
        await pumpPhoneHome(tester);
        for (var i = 0; i < 4; i++) {
          await openSection(tester, 'Clientes');
          await openSection(tester, 'Histórico');
          await openSection(tester, 'Inicio');
        }
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(canGoBack(tester), isFalse);
      }));

  testWidgets('elegir la sección actual solo cierra el menú (sin recargar ni apilar)',
      (tester) => backend.run(() async {
            await pumpPhoneHome(tester);
            await openSection(tester, 'Clientes');
            final loads = backend.calls('GET', '/clients').length;

            await openSection(tester, 'Clientes');
            expect(find.byType(Drawer), findsNothing);
            expect(find.byType(ClientsScreen), findsOneWidget);
            expect(backend.calls('GET', '/clients'), hasLength(loads));
            expect(canGoBack(tester), isFalse);
          }));

  testWidgets('una pantalla CRM reabierta muestra datos actuales', (tester) => backend.run(() async {
        await pumpPhoneHome(tester);
        await openSection(tester, 'Clientes');
        expect(find.text('Nebula Logística S.L.'), findsOneWidget);

        await openSection(tester, 'Histórico');
        clientName = 'Nebula Logística Renombrada S.L.'; // cambio hecho mientras tanto
        await openSection(tester, 'Clientes');

        expect(find.text('Nebula Logística Renombrada S.L.'), findsOneWidget);
        expect(find.text('Nebula Logística S.L.'), findsNothing);
      }));

  testWidgets('la ficha de un cliente sí conserva el botón Atrás', (tester) => backend.run(() async {
        backend.json('GET', '/clients/1', clientDetailJson());
        await pumpPhoneHome(tester);
        await openSection(tester, 'Clientes');
        await tester.tap(find.text('Nebula Logística S.L.'));
        await tester.pumpAndSettle();

        expect(canGoBack(tester), isTrue);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(ClientsScreen), findsOneWidget);
      }));
}
