// Chat V2 y sesión: un 401 del chat ofrece "Iniciar sesión", que cierra la
// sesión y vuelve a AuthScreen; al volver a entrar el chat empieza vacío (sin
// conversation_id ni contexto anteriores). Un único testWidgets por archivo:
// logout() llama a GoogleSignIn.signOut (ver logout_flow_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/auth_screen.dart';
import 'package:frontend/screens/chat_screen.dart';
import 'package:frontend/widgets/chat/chat_empty_state.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_support.dart';

void main() {
  testWidgets('401 en el chat: la sesión se cierra (FE-02) y el chat vuelve a empezar vacío', (tester) async {
    cleanPreferences({'auth_token': fakeJwt()});
    final backend = FakeBackend();
    stubSession(backend);
    backend.json('GET', '/ping', {"status": "ok"});
    final google = FakeGoogleSignInChannel()..install();
    FakeRecorderPlatform(Directory.systemTemp).install();
    useDesktopSurface(tester);

    var chatCalls = 0;
    backend.on('POST', '/chat', (_) async {
      chatCalls++;
      if (chatCalls == 1) {
        return http.Response(
            jsonEncode({
              "type": "answer",
              "content": "Rivera va bien.",
              "metadata": {
                "active_client": {"id": 1, "name": "Rivera"},
                "active_contact": null,
              },
              "conversation_id": 42,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response(jsonEncode({"detail": "Token inválido"}), 401);
    });

    final auth = AuthProvider();
    await backend.run(() async {
      await tester.pumpWidget(providersFor(auth, const CRMVoiceApp()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chat IA').first);
      await tester.pumpAndSettle();
      expect(find.byType(ChatView), findsOneWidget);

      Future<void> send(String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
        await tester.tap(find.byTooltip('Enviar'));
        await tester.pumpAndSettle();
      }

      await send('¿Cómo va Rivera?');
      expect(find.text('Rivera'), findsOneWidget); // chip de contexto

      // FE-02 (H.6): un 401 cierra la sesión en toda la app, sin pasos extra
      await send('¿Y sus actividades?');

      expect(auth.isAuthenticated, isFalse);
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byType(ChatView), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
      // Token caducado no es "cerrar sesión": no se cierra Google ni se bloquea su inicio automático
      expect(prefs.getBool('google_auto_login_disabled'), isNot(isTrue));
      expect(google.calls, isNot(contains('signOut')));

      // Nueva sesión: el estado del chat anterior no sobrevive
      await auth.login('ana@crmvoice.test', 'secreta', false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat IA').first);
      await tester.pumpAndSettle();
      expect(find.text(ChatEmptyState.title), findsOneWidget);
      expect(find.text('Rivera'), findsNothing);

      backend.on('POST', '/chat', (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.containsKey('conversation_id'), isFalse);
        return http.Response(
            jsonEncode({"type": "answer", "content": "Hola.", "metadata": null, "conversation_id": 99}), 200);
      });
      await send('hola');
      expect(find.text('Hola.'), findsOneWidget);
    });

    backend.expectNoUnexpectedRequests();
  });
}
