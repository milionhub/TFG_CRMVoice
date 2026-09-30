// AuthScreen + Google (sin Google real): al abrir, intento de inicio silencioso;
// el botón (no web) lanza el login del plugin y no llama al backend hasta tener
// un ID token. Un único testWidgets por archivo: GoogleSignIn es un singleton
// cuyas llamadas quedan ligadas a la zona FakeAsync del primer test que lo usa
// (ver app_flow_test.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/auth_screen.dart';

import 'support/test_support.dart';

void main() {
  testWidgets('AuthScreen intenta el auto-login y el botón de Google usa el plugin sin llamar al backend',
      (tester) async {
    cleanPreferences();
    final backend = FakeBackend();
    final google = FakeGoogleSignInChannel()..install();
    FakeRecorderPlatform(Directory.systemTemp).install();
    useDesktopSurface(tester);

    await backend.run(() async {
      await tester.pumpWidget(providersFor(AuthProvider(), const CRMVoiceApp()));
      await tester.pumpAndSettle();

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(google.calls, contains('signInSilently')); // One Tap / inicio silencioso

      final googleButton = find.byWidgetPredicate(
          (w) => w is GestureDetector && w.onTap != null && w.child is Container);
      expect(googleButton, findsOneWidget);
      await tester.ensureVisible(googleButton);
      await tester.tap(googleButton);
      await tester.pumpAndSettle();

      expect(google.calls, contains('signIn'));
      // Sin cuenta de Google (el doble devuelve null): nunca se llama a /auth/google
      expect(backend.calls('POST', '/auth/google'), isEmpty);
      expect(find.byType(AuthScreen), findsOneWidget);
    });
    backend.expectNoUnexpectedRequests();
  });
}
