import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// JWT con el mismo formato que emite el backend (la firma no se valida aquí).
String fakeJwt({required int userId, required String email}) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  return '${b64({"alg": "HS256", "typ": "JWT"})}.'
      '${b64({"sub": "$userId", "email": email, "exp": exp})}.firma';
}

/// Backend simulado: /login, /auth/google y /me.
MockClient fakeBackend({bool meUnauthorized = false}) {
  return MockClient((request) async {
    final path = request.url.path;

    if (path == '/login') {
      final body = jsonDecode(request.body);
      return http.Response(jsonEncode({
        "access_token": fakeJwt(userId: 7, email: body["email"]),
        "token_type": "bearer",
        "user": {"id": 7, "nombre": "Test User", "email": body["email"]},
      }), 200);
    }

    if (path == '/auth/google') {
      final body = jsonDecode(request.body);
      // El frontend debe enviar idToken (SEC-03), nunca accessToken
      if (body["idToken"] == null || body.containsKey("accessToken")) {
        return http.Response('{"detail":"Missing token"}', 400);
      }
      return http.Response(jsonEncode({
        "access_token": fakeJwt(userId: 2, email: "google@example.com"),
        "user": {"id": 2, "nombre": "Google User", "email": "google@example.com"},
      }), 200);
    }

    if (path == '/me') {
      if (meUnauthorized) return http.Response('{"detail":"Token inválido"}', 401);
      final token = request.headers["Authorization"]!.substring(7);
      final payload = jsonDecode(utf8.decode(
          base64Url.decode(base64Url.normalize(token.split('.')[1]))));
      final isGoogle = payload["sub"] == "2";
      return http.Response(jsonEncode({
        "id": int.parse(payload["sub"]),
        "nombre": isGoogle ? "Google User" : "Test User",
        "email": payload["email"],
      }), 200);
    }

    return http.Response('not found', 404);
  });
}

/// Simula un F5: nueva instancia de AuthProvider sobre el mismo almacenamiento.
Future<AuthProvider> reload({bool meUnauthorized = false}) {
  return http.runWithClient(() async {
    final auth = AuthProvider();
    await auth.init();
    return auth;
  }, () => fakeBackend(meUnauthorized: meUnauthorized));
}

Future<T> withBackend<T>(Future<T> Function() body) =>
    http.runWithClient(body, fakeBackend);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('login Google + F5 restaura la sesión con nombre y email', () async {
    final auth = await reload();
    expect(await withBackend(() => auth.googleLogin('id-token-falso')), isTrue);
    expect(auth.isAuthenticated, isTrue);

    final afterF5 = await reload();
    expect(afterF5.isAuthenticated, isTrue);
    expect(afterF5.userName, 'Google User');
    expect(afterF5.userEmail, 'google@example.com');
    expect(afterF5.isGoogleAutoLoginSuppressed, isFalse);
  });

  test('logout + F5 permanece en Login y bloquea el auto-login de Google', () async {
    final auth = await reload();
    await withBackend(() => auth.googleLogin('id-token-falso'));

    await auth.logout();
    expect(auth.isAuthenticated, isFalse);
    expect(auth.userName, isNull);
    expect(auth.isGoogleAutoLoginSuppressed, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), isNull);
    expect(prefs.getBool('google_auto_login_disabled'), isTrue);

    // F5: la decisión de logout sobrevive a la recarga
    final afterF5 = await reload();
    expect(afterF5.isAuthenticated, isFalse);
    expect(afterF5.isGoogleAutoLoginSuppressed, isTrue);

    // tryGoogleAutoLogin no reautentica
    await afterF5.tryGoogleAutoLogin();
    expect(afterF5.isAuthenticated, isFalse);

    // Otro F5: sigue igual
    final afterSecondF5 = await reload();
    expect(afterSecondF5.isAuthenticated, isFalse);
    expect(afterSecondF5.isGoogleAutoLoginSuppressed, isTrue);
  });

  test('tras logout + F5, el botón Google manual vuelve a permitir login', () async {
    final auth = await reload();
    await withBackend(() => auth.googleLogin('id-token-falso'));
    await auth.logout();

    final afterF5 = await reload();
    expect(afterF5.isGoogleAutoLoginSuppressed, isTrue);

    // Pulsación voluntaria del botón → onCurrentUserChanged → googleLogin
    expect(await withBackend(() => afterF5.googleLogin('id-token-nuevo')), isTrue);
    expect(afterF5.isAuthenticated, isTrue);
    expect(afterF5.isGoogleAutoLoginSuppressed, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('google_auto_login_disabled'), isNull);

    final afterSecondF5 = await reload();
    expect(afterSecondF5.isAuthenticated, isTrue);
  });

  test('login tradicional con rememberMe + F5 restaura; logout + F5 sigue en Login', () async {
    final auth = await reload();
    expect(await withBackend(() =>
        auth.login('test.crmvoice@example.com', 'x', true)), isTrue);
    expect(auth.userName, 'Test User');

    final afterF5 = await reload();
    expect(afterF5.isAuthenticated, isTrue);
    expect(afterF5.userEmail, 'test.crmvoice@example.com');

    await afterF5.logout();
    final afterLogoutF5 = await reload();
    expect(afterLogoutF5.isAuthenticated, isFalse);
    expect(afterLogoutF5.isGoogleAutoLoginSuppressed, isTrue);
  });

  test('login tradicional tras logout limpia la marca', () async {
    SharedPreferences.setMockInitialValues({'google_auto_login_disabled': true});

    final auth = await reload();
    expect(auth.isGoogleAutoLoginSuppressed, isTrue);

    await withBackend(() => auth.login('test.crmvoice@example.com', 'x', true));
    expect(auth.isGoogleAutoLoginSuppressed, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('google_auto_login_disabled'), isNull);
  });

  test('login sin rememberMe + F5 vuelve a Login (sin tocar la marca)', () async {
    final auth = await reload();
    await withBackend(() => auth.login('test.crmvoice@example.com', 'x', false));
    expect(auth.isAuthenticated, isTrue);

    final afterF5 = await reload();
    expect(afterF5.isAuthenticated, isFalse);
    expect(afterF5.isGoogleAutoLoginSuppressed, isFalse);
  });

  test('sesión rechazada por el backend al restaurar NO cuenta como logout explícito', () async {
    final auth = await reload();
    await withBackend(() => auth.googleLogin('id-token-falso'));

    final afterF5 = await reload(meUnauthorized: true);
    expect(afterF5.isAuthenticated, isFalse);
    expect(afterF5.isGoogleAutoLoginSuppressed, isFalse);
  });
}
