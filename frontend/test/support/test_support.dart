// Infraestructura común de los tests del frontend (no es un test: no termina en _test.dart).
//
// Garantías:
// - HTTP: todo pasa por FakeBackend (package:http/testing MockClient vía
//   http.runWithClient). Una ruta no registrada responde 599 y queda anotada en
//   `unexpected` para que el test falle. El binding de flutter_test responde además
//   400 a cualquier HttpClient real: nunca hay red.
// - Plataforma: google_sign_in, record (micrófono) y path_provider se simulan en
//   sus MethodChannel oficiales. Nada de Google, micrófono ni permisos reales.
// - SharedPreferences: memoria limpia por test (SharedPreferences.setMockInitialValues).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/services/api_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =====================================================================
// JWT con el mismo formato que emite el backend (la firma no se valida aquí)
// =====================================================================

String fakeJwt({
  int userId = 7,
  String email = 'ana@crmvoice.test',
  Duration expiresIn = const Duration(hours: 1),
}) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  return '${b64({"alg": "HS256", "typ": "JWT"})}.'
      '${b64({"sub": "$userId", "email": email, "exp": exp})}.firma';
}

// =====================================================================
// Backend HTTP simulado
// =====================================================================

typedef RouteHandler = FutureOr<http.Response> Function(http.Request request);

class FakeBackend {
  final Map<String, RouteHandler> _routes = {};
  final List<http.Request> requests = [];
  final List<String> unexpected = [];

  /// Registra un handler para "MÉTODO /ruta" (sin query string).
  void on(String method, String path, RouteHandler handler) {
    _routes['$method $path'] = handler;
  }

  /// Atajo: responde siempre con este JSON y status.
  void json(String method, String path, Object? body, {int status = 200}) {
    on(method, path, (_) => http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'}));
  }

  MockClient get client => MockClient((request) async {
        requests.add(request);
        final handler = _routes['${request.method} ${request.url.path}'];
        if (handler == null) {
          unexpected.add('${request.method} ${request.url}');
          return http.Response('{"detail":"ruta no simulada"}', 599);
        }
        return handler(request);
      });

  Future<T> run<T>(Future<T> Function() body) =>
      http.runWithClient(body, () => client);

  List<http.Request> calls(String method, String path) => requests
      .where((r) => r.method == method && r.url.path == path)
      .toList();

  void expectNoUnexpectedRequests() {
    expect(unexpected, isEmpty, reason: 'peticiones HTTP no simuladas');
  }
}

/// Respuestas de sesión estándar: /login, /register y /me.
void stubSession(FakeBackend backend,
    {int userId = 7, String email = 'ana@crmvoice.test', String nombre = 'Ana Test'}) {
  backend.on('POST', '/login', (request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
        jsonEncode({
          "access_token": fakeJwt(userId: userId, email: body["email"]),
          "token_type": "bearer",
          "user": {"id": userId, "nombre": nombre, "email": body["email"]},
        }),
        200);
  });
  backend.json('POST', '/register',
      {"access_token": fakeJwt(userId: userId, email: email), "token_type": "bearer"});
  backend.json('GET', '/me', {"id": userId, "nombre": nombre, "email": email});
}

// =====================================================================
// Canales de plataforma simulados
// =====================================================================

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// google_sign_in (MethodChannelGoogleSignIn): registra las llamadas.
class FakeGoogleSignInChannel {
  static const channel = MethodChannel('plugins.flutter.io/google_sign_in');
  final List<String> calls = [];
  Object? signOutError;

  void install() {
    _messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'signOut' && signOutError != null) throw signOutError!;
      return null; // init/signInSilently/signIn: sin cuenta
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(channel, null));
  }
}

/// Plugin `record` + path_provider: micrófono totalmente simulado.
class FakeRecorderPlatform {
  static const messages = MethodChannel('com.llfbandit.record/messages');
  static const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  final List<String> calls = [];
  final Directory tempDir;

  bool permission = true;
  Completer<bool>? permissionCompleter;
  Completer<void>? startCompleter;
  PlatformException? startError;
  bool isRecordingAfterStart = true;
  PlatformException? stopError;

  /// Ruta que devuelve stop(); por defecto la que se pasó a start().
  String? Function(String? startedPath)? stopPath;
  String? startedPath;

  FakeRecorderPlatform(this.tempDir);

  void install() {
    _messenger.setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getTemporaryDirectory') return tempDir.path;
      return null;
    });
    _messenger.setMockMethodCallHandler(messages, (call) async {
      calls.add(call.method);
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'create':
          // El EventChannel de estado lleva el id del grabador en el nombre
          final events = MethodChannel('com.llfbandit.record/events/${args['recorderId']}');
          // Se deja registrado: el widget se desmonta después del teardown y
          // AudioRecorder.dispose cancela el stream (el id es único por grabador)
          _messenger.setMockMethodCallHandler(events, (_) async => null);
          return null;
        case 'hasPermission':
          if (permissionCompleter != null) return permissionCompleter!.future;
          return permission;
        case 'start':
          startedPath = args['path'] as String?;
          if (startError != null) throw startError!;
          if (startCompleter != null) await startCompleter!.future;
          return null;
        case 'isRecording':
          return isRecordingAfterStart;
        case 'stop':
          if (stopError != null) throw stopError!;
          return stopPath == null ? startedPath : stopPath!(startedPath);
        default: // cancel, dispose, ...
          return null;
      }
    });
    // Sin teardown: AudioRecorder.dispose (al desmontar el widget, después del
    // teardown del test) sigue necesitando el canal. Cada test lo reinstala.
  }

  int count(String method) => calls.where((c) => c == method).length;
}

// =====================================================================
// Montaje de pantallas con los providers reales (como main.dart)
// =====================================================================

/// Sesión autenticada real (AuthProvider.login contra FakeBackend).
Future<AuthProvider> loggedInAuth(FakeBackend backend,
    {String email = 'ana@crmvoice.test'}) async {
  stubSession(backend, email: email);
  final auth = AuthProvider();
  await backend.run(() => auth.login(email, 'secreta', false));
  return auth;
}

Widget providersFor(AuthProvider auth, Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ProxyProvider<AuthProvider, ApiService>(update: (context, a, previous) => ApiService(a)),
    ],
    child: child,
  );
}

Widget appFor(AuthProvider auth, Widget home) =>
    providersFor(auth, MaterialApp(home: home));

/// Superficie de escritorio (>= 800 px): los layouts eligen versión desktop.
void useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Estado limpio de SharedPreferences para cada test.
void cleanPreferences([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
}
