// ChatScreen (P1): envía el mensaje con el token, muestra la respuesta y
// controla los errores del servidor y de red. El chat usa http.post
// directamente (no ApiService): también pasa por FakeBackend.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/chat_screen.dart';
import 'package:http/http.dart' as http;

import 'support/test_support.dart';

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpChat(WidgetTester tester) async {
    useDesktopSurface(tester);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const ChatScreen()));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
  }

  bool shows(String text) => find.textContaining(text, findRichText: true).evaluate().isNotEmpty;

  testWidgets('muestra el mensaje de bienvenida', (tester) => backend.run(() async {
        await pumpChat(tester);

        expect(shows('Soy tu asistente CRM'), isTrue);
      }));

  testWidgets('envía el mensaje con Bearer y muestra la respuesta', (tester) => backend.run(() async {
        backend.json('POST', '/chat', {"type": "prepare_meeting", "content": "Facturación de Nebula: 300 €",
          "metadata": null});
        await pumpChat(tester);

        await send(tester, '¿Cuánto factura Nebula?');

        final request = backend.calls('POST', '/chat').single;
        expect(jsonDecode(request.body), {"message": "¿Cuánto factura Nebula?"});
        expect(request.headers['Authorization'], startsWith('Bearer '));
        expect(shows('¿Cuánto factura Nebula?'), isTrue);
        expect(shows('Facturación de Nebula: 300 €'), isTrue);
      }));

  testWidgets('mensaje vacío no se envía', (tester) => backend.run(() async {
        await pumpChat(tester);

        await send(tester, '   ');

        expect(backend.calls('POST', '/chat'), isEmpty);
      }));

  testWidgets('error del servidor: "Error del servidor"', (tester) => backend.run(() async {
        backend.json('POST', '/chat', {"detail": "error"}, status: 500);
        await pumpChat(tester);

        await send(tester, 'hola');

        expect(shows('Error del servidor'), isTrue);
      }));

  testWidgets('error de red: "Error de conexión"', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => throw http.ClientException('sin conexión'));
        await pumpChat(tester);

        await send(tester, 'hola');

        expect(shows('Error de conexión'), isTrue);
      }));
}
