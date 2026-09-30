// Logout desde Home (P0): vuelve a AuthScreen, borra el token y bloquea el
// auto-login de Google. Un único testWidgets por archivo: logout() llama a
// GoogleSignIn.signOut y ese singleton no admite varios tests FakeAsync en el
// mismo archivo (ver app_flow_test.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/auth_screen.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_support.dart';

void main() {
  testWidgets('logout desde el sidebar vuelve a AuthScreen, borra el token y marca el auto-login', (tester) async {
    cleanPreferences({'auth_token': fakeJwt()});
    final backend = FakeBackend();
    stubSession(backend, nombre: 'Ana Test');
    backend.json('GET', '/ping', {"status": "ok"});
    final google = FakeGoogleSignInChannel()..install();
    FakeRecorderPlatform(Directory.systemTemp).install();
    useDesktopSurface(tester);

    await backend.run(() async {
      await tester.pumpWidget(providersFor(AuthProvider(), const CRMVoiceApp()));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Ana Test'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.text('Ana Test'), findsNothing);
    });

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), isNull);
    expect(prefs.getBool('google_auto_login_disabled'), isTrue);
    expect(google.calls, contains('signOut'));
    // Tras el logout, AuthScreen no reintenta el inicio silencioso de Google
    expect(google.calls, isNot(contains('signInSilently')));
    backend.expectNoUnexpectedRequests();
  });
}
