// GoogleAuthService (P1). (El modelo Activity y ActivityProvider, sin uso, se
// eliminaron en H.5.2.)
// GoogleAuthService: solo lógica propia; el plugin se simula en su canal.
// La rama web (kIsWeb, botón oficial, GOOGLE_CLIENT_ID vacío) no es
// alcanzable desde flutter test (kIsWeb es constante false en la VM).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/google_auth_service.dart';

import 'support/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GoogleAuthService', () {
    late FakeGoogleSignInChannel google;

    setUp(() => google = FakeGoogleSignInChannel()..install());

    test('es un singleton (una sola instancia del plugin en toda la app)', () {
      expect(identical(GoogleAuthService(), GoogleAuthService()), isTrue);
    });

    test('fuera de web se considera configurado y no hay Client ID por defecto', () {
      expect(GoogleAuthService.isConfigured, isTrue);
      expect(GoogleAuthService.clientId, isEmpty);
    });

    test('signOut no propaga errores del plugin', () async {
      google.signOutError = PlatformException(code: 'sign_out_failed');

      await expectLater(GoogleAuthService().signOut(), completes);
      expect(google.calls, contains('signOut'));
    });

    test('signInSilently sin cuenta previa no lanza', () async {
      await expectLater(GoogleAuthService().signInSilently(), completes);
      expect(google.calls, contains('signInSilently'));
    });
  });
}
