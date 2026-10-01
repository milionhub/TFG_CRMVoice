// ChatScreen (P1): envía el mensaje con el token, muestra la respuesta y
// controla los errores del servidor y de red. El chat usa http.post
// directamente (no ApiService): también pasa por FakeBackend.
// G.3: conversation_id en memoria (omitido en el primer mensaje, reutilizado
// después, descartado con 404), sin doble envío y sin "Bearer null".
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/chat_screen.dart';
import 'package:frontend/providers/auth_provider.dart';
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
        backend.json('POST', '/chat', {"type": "answer", "content": "Facturación de Nebula: 300 €",
          "metadata": null, "conversation_id": 1});
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

  http.Response chatReply(String content, int? conversationId) => http.Response(
      jsonEncode({"type": "answer", "content": content, "metadata": null, "conversation_id": conversationId}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'});

  List<dynamic> chatBodies() => backend.calls('POST', '/chat').map((r) => jsonDecode(r.body)).toList();

  testWidgets('el primer mensaje no lleva conversation_id y los siguientes reutilizan el devuelto',
      (tester) => backend.run(() async {
            var n = 0;
            backend.on('POST', '/chat', (_) => chatReply('Respuesta ${++n}', 42));
            await pumpChat(tester);

            await send(tester, 'primera');
            await send(tester, 'segunda');

            expect(chatBodies(), [
              {"message": "primera"},
              {"message": "segunda", "conversation_id": 42},
            ]);
            expect(shows('Respuesta 2'), isTrue);
          }));

  testWidgets('un 404 descarta la conversación y la siguiente pregunta empieza otra',
      (tester) => backend.run(() async {
            final replies = <http.Response>[
              chatReply('uno', 42),
              http.Response('{"detail": "Conversación no encontrada"}', 404,
                  headers: {'content-type': 'application/json; charset=utf-8'}),
              chatReply('tres', 43),
            ];
            backend.on('POST', '/chat', (_) => replies.removeAt(0));
            await pumpChat(tester);

            await send(tester, 'uno');
            await send(tester, 'dos');
            expect(shows('La conversación ya no está disponible'), isTrue);
            await send(tester, 'tres');

            expect(chatBodies(), [
              {"message": "uno"},
              {"message": "dos", "conversation_id": 42},
              {"message": "tres"},
            ]);
          }));

  testWidgets('no se envía otro mensaje mientras se espera la respuesta', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        backend.on('POST', '/chat', (_) => pending.future);
        await pumpChat(tester);

        await tester.enterText(find.byType(TextField), 'uno');
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'dos');
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();

        expect(backend.calls('POST', '/chat'), hasLength(1));

        pending.complete(chatReply('hecho', 7));
        await tester.pumpAndSettle();
        expect(shows('hecho'), isTrue);
      }));

  testWidgets('sin token no envía "Bearer null"', (tester) => backend.run(() async {
        backend.json('POST', '/chat', {"detail": "Not authenticated"}, status: 401);
        useDesktopSurface(tester);
        await tester.pumpWidget(appFor(AuthProvider(), const ChatScreen()));
        await tester.pumpAndSettle();

        await send(tester, 'hola');

        final request = backend.calls('POST', '/chat').single;
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(shows('Error del servidor'), isTrue);
      }));
}
