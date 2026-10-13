// AuthProvider (P0): estado, login/registro, restauración con /me, persistencia,
// logout, notificaciones y control del auto-login de Google.
// Complementa auth_provider_logout_test.dart (flujos F5/logout ya cubiertos).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_support.dart';

const _tokenKey = 'auth_token';
const _googleKey = 'google_auto_login_disabled';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBackend backend;
  late FakeGoogleSignInChannel google;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    google = FakeGoogleSignInChannel()..install();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  // -------------------------------------------------------------------
  // Estado inicial e init()
  // -------------------------------------------------------------------

  test('estado inicial: sin sesión, sin inicializar, sin carga', () {
    final auth = AuthProvider();

    expect(auth.token, isNull);
    expect(auth.isAuthenticated, isFalse);
    expect(auth.isInitialized, isFalse);
    expect(auth.isLoading, isFalse);
    expect(auth.userName, isNull);
    expect(auth.userEmail, isNull);
  });

  test('init sin token guardado: inicializado, sin sesión y sin llamar al backend', () async {
    final auth = AuthProvider();
    var notifications = 0;
    auth.addListener(() => notifications++);

    await backend.run(auth.init);

    expect(auth.isInitialized, isTrue);
    expect(auth.isAuthenticated, isFalse);
    expect(backend.requests, isEmpty);
    expect(notifications, 1);
  });

  test('init con token válido restaura la sesión e hidrata el usuario desde /me', () async {
    final token = fakeJwt(userId: 3, email: 'guardado@crmvoice.test');
    cleanPreferences({_tokenKey: token});
    backend.json('GET', '/me', {"id": 3, "nombre": "Nombre Servidor", "email": "servidor@crmvoice.test"});
    final auth = AuthProvider();

    await backend.run(auth.init);

    expect(auth.isAuthenticated, isTrue);
    expect(auth.token, token);
    expect(auth.userName, 'Nombre Servidor');
    expect(auth.userEmail, 'servidor@crmvoice.test');
    final me = backend.calls('GET', '/me').single;
    expect(me.headers['Authorization'], 'Bearer $token');
  });

  test('init con token caducado lo borra sin llamar a /me', () async {
    cleanPreferences({_tokenKey: fakeJwt(expiresIn: const Duration(minutes: -5))});
    final auth = AuthProvider();

    await backend.run(auth.init);

    expect(auth.isAuthenticated, isFalse);
    expect(backend.requests, isEmpty);
    expect((await prefs()).getString(_tokenKey), isNull);
  });

  for (final status in [401, 403]) {
    test('init: /me $status limpia la sesión y el token guardado', () async {
      cleanPreferences({_tokenKey: fakeJwt()});
      backend.json('GET', '/me', {"detail": "Token inválido"}, status: status);
      final auth = AuthProvider();

      await backend.run(auth.init);

      expect(auth.isAuthenticated, isFalse);
      expect(auth.token, isNull);
      expect(auth.userName, isNull);
      expect(auth.userEmail, isNull);
      expect((await prefs()).getString(_tokenKey), isNull);
      expect(auth.isInitialized, isTrue);
    });
  }

  test('init: /me 500 o sin conexión mantiene la sesión con el email del token (modo offline)', () async {
    final token = fakeJwt(email: 'offline@crmvoice.test');
    cleanPreferences({_tokenKey: token});
    backend.json('GET', '/me', {"detail": "error"}, status: 500);
    final auth = AuthProvider();

    await backend.run(auth.init);

    expect(auth.isAuthenticated, isTrue);
    expect(auth.userEmail, 'offline@crmvoice.test');
    expect((await prefs()).getString(_tokenKey), token);
  });

  // -------------------------------------------------------------------
  // Login
  // -------------------------------------------------------------------

  test('login correcto: token, usuario, petición y notificaciones de carga', () async {
    stubSession(backend, userId: 9, nombre: 'Ana Test');
    final auth = AuthProvider();
    final loadingStates = <bool>[];
    auth.addListener(() => loadingStates.add(auth.isLoading));

    final ok = await backend.run(() => auth.login('ana@crmvoice.test', 'secreta', true));

    expect(ok, isTrue);
    expect(auth.isAuthenticated, isTrue);
    expect(auth.userName, 'Ana Test');
    expect(auth.userEmail, 'ana@crmvoice.test');
    expect(auth.isLoading, isFalse);
    expect(loadingStates, [true, false]);

    final request = backend.calls('POST', '/login').single;
    expect(jsonDecode(request.body), {"email": "ana@crmvoice.test", "password": "secreta"});
    expect(request.headers.containsKey('Authorization'), isFalse);
  });

  test('I.6.3: la sesión caducada deja un aviso de un solo uso que un login correcto descarta', () async {
    stubSession(backend, userId: 9, nombre: 'Ana Test');
    final auth = AuthProvider();
    await backend.run(() => auth.login('ana@crmvoice.test', 'secreta', false));
    expect(auth.takeSessionExpiredNotice(), isFalse);

    await auth.expireSession();
    expect(auth.isAuthenticated, isFalse);
    expect(auth.takeSessionExpiredNotice(), isTrue);
    expect(auth.takeSessionExpiredNotice(), isFalse, reason: 'solo una vez');

    await auth.expireSession(); // sin sesión: no vuelve a avisar
    expect(auth.takeSessionExpiredNotice(), isFalse);

    await backend.run(() => auth.login('ana@crmvoice.test', 'secreta', false));
    await auth.expireSession();
    await backend.run(() => auth.login('ana@crmvoice.test', 'secreta', false));
    expect(auth.takeSessionExpiredNotice(), isFalse, reason: 'un login correcto lo descarta');
  });

  test('login con rememberMe persiste el token; sin rememberMe no', () async {
    stubSession(backend);

    final remembered = AuthProvider();
    await backend.run(() => remembered.login('ana@crmvoice.test', 'x', true));
    expect((await prefs()).getString(_tokenKey), remembered.token);

    cleanPreferences();
    final notRemembered = AuthProvider();
    await backend.run(() => notRemembered.login('ana@crmvoice.test', 'x', false));
    expect(notRemembered.isAuthenticated, isTrue);
    expect((await prefs()).getString(_tokenKey), isNull);
  });

  test('login sin "user" en la respuesta usa el email como nombre', () async {
    backend.json('POST', '/login', {"access_token": fakeJwt(), "token_type": "bearer"});
    final auth = AuthProvider();

    await backend.run(() => auth.login('laura@crmvoice.test', 'x', false));

    expect(auth.userEmail, 'laura@crmvoice.test');
    expect(auth.userName, 'laura');
  });

  for (final status in [401, 422, 500]) {
    test('login fallido ($status): false, sin token ni usuario fantasma', () async {
      backend.json('POST', '/login', {"detail": "Password incorrecto"}, status: status);
      final auth = AuthProvider();

      final ok = await backend.run(() => auth.login('ana@crmvoice.test', 'mala', true));

      expect(ok, isFalse);
      expect(auth.token, isNull);
      expect(auth.isAuthenticated, isFalse);
      expect(auth.userName, isNull);
      expect(auth.isLoading, isFalse);
      expect((await prefs()).getString(_tokenKey), isNull);
    });
  }

  test('login con error de red: false y sin sesión', () async {
    backend.on('POST', '/login', (_) => throw http.ClientException('sin conexión'));
    final auth = AuthProvider();

    final ok = await backend.run(() => auth.login('ana@crmvoice.test', 'x', true));

    expect(ok, isFalse);
    expect(auth.isAuthenticated, isFalse);
    expect(auth.isLoading, isFalse);
  });

  test('isLoading es true mientras el login está en curso', () async {
    final pending = Completer<http.Response>();
    backend.on('POST', '/login', (_) => pending.future);
    final auth = AuthProvider();

    final future = backend.run(() => auth.login('ana@crmvoice.test', 'x', false));
    await Future<void>.delayed(Duration.zero);
    expect(auth.isLoading, isTrue);

    pending.complete(http.Response('{"detail":"no"}', 401));
    await future;
    expect(auth.isLoading, isFalse);
  });

  // -------------------------------------------------------------------
  // Registro
  // -------------------------------------------------------------------

  test('registro correcto: envía los datos, pide /me y guarda el token si rememberMe', () async {
    stubSession(backend, userId: 11, nombre: 'Nombre del Servidor', email: 'nuevo@crmvoice.test');
    final auth = AuthProvider();

    final ok = await backend.run(() => auth.register('Nuevo', 'nuevo@crmvoice.test', 'secreta', true));

    expect(ok, isTrue);
    expect(auth.isAuthenticated, isTrue);
    expect(auth.userName, 'Nombre del Servidor'); // hidratado desde /me
    expect(jsonDecode(backend.calls('POST', '/register').single.body),
        {"nombre": "Nuevo", "email": "nuevo@crmvoice.test", "password": "secreta"});
    expect(backend.calls('GET', '/me').single.headers['Authorization'], 'Bearer ${auth.token}');
    expect((await prefs()).getString(_tokenKey), auth.token);
  });

  test('registro fallido (email duplicado): false y sin sesión', () async {
    backend.json('POST', '/register', {"detail": "El email ya está registrado"}, status: 400);
    final auth = AuthProvider();

    final ok = await backend.run(() => auth.register('X', 'dup@crmvoice.test', 'secreta', true));

    expect(ok, isFalse);
    expect(auth.isAuthenticated, isFalse);
    expect(auth.isLoading, isFalse);
    expect((await prefs()).getString(_tokenKey), isNull);
  });

  // -------------------------------------------------------------------
  // Logout
  // -------------------------------------------------------------------

  test('logout: borra token y usuario, marca el auto-login de Google, cierra Google y notifica', () async {
    stubSession(backend);
    final auth = AuthProvider();
    await backend.run(() => auth.login('ana@crmvoice.test', 'x', true));
    var notified = false;
    auth.addListener(() => notified = true);

    await auth.logout();

    expect(auth.token, isNull);
    expect(auth.isAuthenticated, isFalse);
    expect(auth.userName, isNull);
    expect(auth.userEmail, isNull);
    expect(auth.user, isNull);
    expect(auth.isLoading, isFalse);
    expect(notified, isTrue);
    expect((await prefs()).getString(_tokenKey), isNull);
    expect((await prefs()).getBool(_googleKey), isTrue);
    expect(google.calls, contains('signOut'));
  });

  test('logout funciona aunque el cierre de sesión de Google falle', () async {
    google.signOutError = PlatformException(code: 'sign_out_failed');
    stubSession(backend);
    final auth = AuthProvider();
    await backend.run(() => auth.login('ana@crmvoice.test', 'x', true));

    await auth.logout();

    expect(auth.isAuthenticated, isFalse);
    expect((await prefs()).getString(_tokenKey), isNull);
  });

  // -------------------------------------------------------------------
  // Google (solo lógica propia: sin Google real)
  // -------------------------------------------------------------------

  test('googleLogin envía idToken (nunca accessToken) y guarda la sesión', () async {
    backend.json('POST', '/auth/google', {
      "access_token": fakeJwt(userId: 2, email: 'g@crmvoice.test'),
      "user": {"id": 2, "nombre": "Google User", "email": "g@crmvoice.test"},
    });
    final auth = AuthProvider();

    final ok = await backend.run(() => auth.googleLogin('id-token-simulado'));

    expect(ok, isTrue);
    expect(jsonDecode(backend.calls('POST', '/auth/google').single.body), {"idToken": "id-token-simulado"});
    expect(auth.userName, 'Google User');
    expect((await prefs()).getString(_tokenKey), auth.token);
  });

  for (final status in [401, 409, 503]) {
    test('googleLogin rechazado por el backend ($status): false y sin sesión', () async {
      backend.json('POST', '/auth/google', {"detail": "error"}, status: status);
      final auth = AuthProvider();

      final ok = await backend.run(() => auth.googleLogin('id-token'));

      expect(ok, isFalse);
      expect(auth.isAuthenticated, isFalse);
      expect((await prefs()).getString(_tokenKey), isNull);
    });
  }

  test('googleLogin con error de red: false y sin sesión', () async {
    backend.on('POST', '/auth/google', (_) => throw http.ClientException('sin conexión'));
    final auth = AuthProvider();

    expect(await backend.run(() => auth.googleLogin('id-token')), isFalse);
    expect(auth.isAuthenticated, isFalse);
  });

  test('tryGoogleAutoLogin intenta el inicio silencioso solo si procede', () async {
    // Sin sesión y sin marca: sí
    final fresh = AuthProvider();
    await backend.run(fresh.init);
    await fresh.tryGoogleAutoLogin();
    expect(google.calls, contains('signInSilently'));

    // Tras un logout explícito (marca persistida): no
    google.calls.clear();
    cleanPreferences({_googleKey: true});
    final suppressed = AuthProvider();
    await backend.run(suppressed.init);
    await suppressed.tryGoogleAutoLogin();
    expect(google.calls, isNot(contains('signInSilently')));

    // Con sesión ya iniciada: no
    google.calls.clear();
    cleanPreferences();
    final logged = await loggedInAuth(backend);
    await logged.tryGoogleAutoLogin();
    expect(google.calls, isNot(contains('signInSilently')));
  });
}
