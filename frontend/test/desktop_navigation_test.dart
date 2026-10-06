// H.6 · Navegación de escritorio: la barra lateral sustituye TODA la pila, como
// el menú móvil. Defecto encontrado: Voice V2 ("Ver en Histórico") apila
// Histórico sobre Home y la barra lateral solo reemplazaba la ruta superior,
// así que cada ida y vuelta dejaba otra Home antigua debajo (pila creciente).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/clients_screen.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:frontend/screens/home_screen.dart';

import 'support/test_support.dart';

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    FakeRecorderPlatform(Directory.systemTemp).install();
    backend.json('GET', '/ping', {"status": "ok"});
    backend.json('GET', '/clients', {
      "clients": [
        {"id": 1, "name": "Nebula Logística S.L."}
      ]
    });
    backend.json('GET', '/activities', {"activities": []});
    backend.json('GET', '/activity-types', {"activity_types": []});
    backend.json('GET', '/products', {"products": []});
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  NavigatorState navigator(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first);

  Future<void> sidebar(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(Sidebar), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  testWidgets('tras una pantalla apilada sobre Home (Voice V2), la barra lateral no deja Homes antiguas',
      (tester) => backend.run(() async {
            useDesktopSurface(tester);
            final auth = await loggedInAuth(backend);
            await tester.pumpWidget(appFor(auth, const HomeScreen()));
            await tester.pumpAndSettle();

            for (var i = 0; i < 3; i++) {
              // Lo que hace RecorderCard tras confirmar: «Ver en Histórico» (push sobre Home)
              navigator(tester).push(MaterialPageRoute(builder: (_) => const HistoryScreen()));
              await tester.pumpAndSettle();
              await sidebar(tester, 'Inicio');
            }

            expect(find.byType(HomeScreen), findsOneWidget);
            expect(navigator(tester).canPop(), isFalse, reason: 'una sola ruta en la pila');
          }));

  testWidgets('cada sección de la barra lateral queda sola en la pila', (tester) => backend.run(() async {
        useDesktopSurface(tester);
        final auth = await loggedInAuth(backend);
        await tester.pumpWidget(appFor(auth, const HomeScreen()));
        await tester.pumpAndSettle();

        await sidebar(tester, 'Clientes');
        expect(find.byType(ClientsScreen), findsOneWidget);
        expect(navigator(tester).canPop(), isFalse);
        await sidebar(tester, 'Histórico');
        expect(find.byType(HistoryScreen), findsOneWidget);
        expect(find.byType(ClientsScreen), findsNothing);
        expect(navigator(tester).canPop(), isFalse);
      }));
}
