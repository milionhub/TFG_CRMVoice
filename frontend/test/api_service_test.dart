// ApiService (P0): contrato HTTP real contra un backend simulado.
// URLs, cabeceras (Bearer / Content-Type), JSON, status y errores de red.
// Sin cambios de producción: ApiService usa las funciones globales de
// package:http, que http.runWithClient redirige al MockClient de FakeBackend.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/services/api_service.dart';
import 'package:http/http.dart' as http;

import 'support/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<ApiService> authedApi() async => ApiService(await loggedInAuth(backend));

  ApiService anonymousApi() => ApiService(AuthProvider());

  http.Request only(String method, String path) => backend.calls(method, path).single;

  // -------------------------------------------------------------------
  // URL base y cabeceras
  // -------------------------------------------------------------------

  test('la URL base por defecto es la del backend local', () {
    expect(ApiService.baseUrl, 'http://127.0.0.1:8000');
  });

  test('con sesión: Authorization Bearer y Content-Type JSON', () async {
    final api = await authedApi();
    backend.json('GET', '/clients', {"clients": []});

    await backend.run(api.getClients);

    final request = only('GET', '/clients');
    expect(request.url.toString(), 'http://127.0.0.1:8000/clients');
    expect(request.headers['Authorization'], 'Bearer ${api.auth.token}');
    expect(request.headers['Content-Type'], startsWith('application/json'));
  });

  test('sin sesión no se envía Authorization (ni "Bearer null")', () async {
    backend.json('GET', '/clients', {"clients": []});

    await backend.run(anonymousApi().getClients);

    expect(only('GET', '/clients').headers.containsKey('Authorization'), isFalse);
  });

  test('login/register/me son estáticos y no usan el token de la sesión', () async {
    stubSession(backend);

    await backend.run(() => ApiService.login('ana@crmvoice.test', 'x'));
    await backend.run(() => ApiService.register('Ana', 'ana@crmvoice.test', 'x'));
    await backend.run(() => ApiService.fetchMe('token-explicito'));

    expect(only('POST', '/login').headers.containsKey('Authorization'), isFalse);
    expect(only('POST', '/register').headers.containsKey('Authorization'), isFalse);
    expect(only('GET', '/me').headers['Authorization'], 'Bearer token-explicito');
  });

  // -------------------------------------------------------------------
  // Actividades
  // -------------------------------------------------------------------

  test('getActivities: devuelve la lista con sus productos intactos', () async {
    final api = await authedApi();
    final activity = {
      "id": 1, "fecha": "2026-10-01T10:00:00", "cliente": "Nebula", "comentario": "x",
      "products": [{"product_id": 4, "product_raw": "Monitor Vela 24"}],
    };
    backend.json('GET', '/activities', {"count": 1, "activities": [activity]});

    final result = await backend.run(() => api.getActivities());

    expect(result, [activity]);
    expect(only('GET', '/activities').url.queryParameters, isEmpty);
  });

  test('getActivities: solo envía los filtros informados', () async {
    final api = await authedApi();
    backend.json('GET', '/activities', {"activities": []});

    await backend.run(() => api.getActivities(clientId: 3, actionId: 2, dateFrom: '2026-10-01', dateTo: ''));

    expect(only('GET', '/activities').url.queryParameters,
        {"client_id": "3", "action_id": "2", "date_from": "2026-10-01"});
  });

  for (final status in [401, 404, 500]) {
    test('getActivities $status lanza excepción', () async {
      final api = await authedApi();
      backend.json('GET', '/activities', {"detail": "x"}, status: status);

      await expectLater(backend.run(() => api.getActivities()), throwsException);
    });
  }

  test('createActivity: POST con el payload en JSON (productos incluidos) y devuelve el body', () async {
    final api = await authedApi();
    backend.json('POST', '/activities', {"success": true, "activity_id": 42});
    final payload = {
      "cliente_id": 1, "contacto_id": 2, "activity_type_id": 3,
      "products_detected": [{"product_id": 4, "product_raw": "Monitor", "confidence": 95}],
    };

    final result = await backend.run(() => api.createActivity(payload));

    expect(result, {"success": true, "activity_id": 42});
    expect(jsonDecode(only('POST', '/activities').body), payload);
  });

  test('createActivity: un {"error"} con 200 se devuelve tal cual (contrato actual del backend)', () async {
    final api = await authedApi();
    backend.json('POST', '/activities', {"error": "Cliente obligatorio"});

    expect(await backend.run(() => api.createActivity({})), {"error": "Cliente obligatorio"});
  });

  test('createActivity: respuesta no JSON (500) lanza FormatException', () async {
    final api = await authedApi();
    backend.on('POST', '/activities', (_) => http.Response('Internal Server Error', 500));

    await expectLater(backend.run(() => api.createActivity({})), throwsFormatException);
  });

  test('updateActivity: PUT /activities/{id} con JSON; success true -> true', () async {
    final api = await authedApi();
    backend.json('PUT', '/activities/5', {"success": true});

    final ok = await backend.run(() => api.updateActivity(5, {"fecha": "2026-10-02T09:00:00", "products": []}));

    expect(ok, isTrue);
    expect(jsonDecode(only('PUT', '/activities/5').body), {"fecha": "2026-10-02T09:00:00", "products": []});
  });

  test('updateActivity: success false, 404 o 500 -> false (sin excepción)', () async {
    final api = await authedApi();
    backend.json('PUT', '/activities/1', {"success": false, "error": "x"});
    backend.json('PUT', '/activities/2', {"detail": "Actividad no encontrada"}, status: 404);
    backend.on('PUT', '/activities/3', (_) => http.Response('Internal Server Error', 500));

    expect(await backend.run(() => api.updateActivity(1, {})), isFalse);
    expect(await backend.run(() => api.updateActivity(2, {})), isFalse);
    expect(await backend.run(() => api.updateActivity(3, {})), isFalse);
  });

  test('deleteActivity: 200 ok; 404 lanza excepción', () async {
    final api = await authedApi();
    backend.json('DELETE', '/activities/8', {"success": true});
    backend.json('DELETE', '/activities/9', {"detail": "Actividad no encontrada"}, status: 404);

    await backend.run(() => api.deleteActivity(8));
    await expectLater(backend.run(() => api.deleteActivity(9)), throwsException);
    expect(only('DELETE', '/activities/8').headers['Authorization'], startsWith('Bearer '));
  });

  // -------------------------------------------------------------------
  // Catálogo
  // -------------------------------------------------------------------

  test('clientes, contactos (filtro por cliente), tipos y productos', () async {
    final api = await authedApi();
    backend.json('GET', '/clients', {"clients": [{"id": 1, "name": "Nebula"}]});
    backend.json('GET', '/contacts', {"contacts": [{"id": 2, "name": "Nora"}]});
    backend.json('GET', '/activity-types', {"activity_types": [{"id": 3, "name": "Concertar reunión"}]});
    backend.json('GET', '/products', {"products": [{"id": 4, "name": "Monitor", "price": 189.0}]});

    expect(await backend.run(api.getClients), [{"id": 1, "name": "Nebula"}]);
    expect(await backend.run(() => api.getContacts(clientId: 1)), [{"id": 2, "name": "Nora"}]);
    expect(await backend.run(() => api.getContacts()), [{"id": 2, "name": "Nora"}]);
    expect(await backend.run(api.getActivityTypes), [{"id": 3, "name": "Concertar reunión"}]);
    expect(await backend.run(api.getProducts), [{"id": 4, "name": "Monitor", "price": 189.0}]);

    final contacts = backend.calls('GET', '/contacts');
    expect(contacts[0].url.queryParameters, {"client_id": "1"});
    expect(contacts[1].url.queryParameters, isEmpty);
  });

  test('catálogo con error (401/500) lanza excepción', () async {
    final api = await authedApi();
    backend.json('GET', '/clients', {"detail": "Token inválido"}, status: 401);
    backend.json('GET', '/products', {"detail": "error"}, status: 500);

    await expectLater(backend.run(api.getClients), throwsException);
    await expectLater(backend.run(api.getProducts), throwsException);
  });

  // -------------------------------------------------------------------
  // Sesión (estáticos)
  // -------------------------------------------------------------------

  test('login: 200 devuelve el body; 401 lanza excepción', () async {
    stubSession(backend);
    expect((await backend.run(() => ApiService.login('ana@crmvoice.test', 'x')))["token_type"], 'bearer');

    final failing = FakeBackend()..json('POST', '/login', {"detail": "Password incorrecto"}, status: 401);
    await expectLater(failing.run(() => ApiService.login('ana@crmvoice.test', 'mala')), throwsException);
  });

  test('register: 400 (email duplicado) y 422 lanzan excepción', () async {
    backend.json('POST', '/register', {"detail": "El email ya está registrado"}, status: 400);
    await expectLater(backend.run(() => ApiService.register('A', 'a@crmvoice.test', 'x')), throwsException);

    final invalid = FakeBackend()..json('POST', '/register', {"detail": []}, status: 422);
    await expectLater(invalid.run(() => ApiService.register('A', 'mal', 'x')), throwsException);
  });

  test('fetchMe: 200 datos; 401/403 null; 500 lanza excepción', () async {
    backend.json('GET', '/me', {"id": 1, "nombre": "Ana", "email": "a@crmvoice.test"});
    expect(await backend.run(() => ApiService.fetchMe('t')), {"id": 1, "nombre": "Ana", "email": "a@crmvoice.test"});

    for (final status in [401, 403]) {
      final b = FakeBackend()..json('GET', '/me', {"detail": "x"}, status: status);
      expect(await b.run(() => ApiService.fetchMe('t')), isNull);
    }

    final broken = FakeBackend()..json('GET', '/me', {"detail": "x"}, status: 500);
    await expectLater(broken.run(() => ApiService.fetchMe('t')), throwsException);
  });

  // -------------------------------------------------------------------
  // Audio y utilidades
  // -------------------------------------------------------------------

  test('uploadAudio: multipart con el campo "file", nombre y Bearer; 200 devuelve el análisis', () async {
    final api = await authedApi();
    backend.json('POST', '/process-audio', {"texto": "hola", "cliente_id": 1});

    final result = await backend.run(() => api.uploadAudio(bytes: [1, 2, 3, 4], filename: 'audio_1.m4a'));

    expect(result, {"texto": "hola", "cliente_id": 1});
    final request = only('POST', '/process-audio');
    expect(request.headers['Authorization'], 'Bearer ${api.auth.token}');
    expect(request.headers['content-type'], startsWith('multipart/form-data'));
    final body = latin1.decode(request.bodyBytes);
    expect(body, contains('name="file"'));
    expect(body, contains('filename="audio_1.m4a"'));
  });

  for (final status in [400, 413, 415, 500]) {
    test('uploadAudio $status lanza excepción con el status', () async {
      final api = await authedApi();
      backend.json('POST', '/process-audio', {"detail": "error"}, status: status);

      await expectLater(backend.run(() => api.uploadAudio(bytes: [1], filename: 'a.webm')),
          throwsA(predicate((e) => e.toString().contains('($status)'))));
    });
  }

  test('ping: devuelve "ok" con la respuesta real de /ping', () async {
    backend.json('GET', '/ping', {"status": "ok"});

    expect(await backend.run(anonymousApi().ping), 'ok');
  });

  test('error de red: la excepción del cliente HTTP se propaga', () async {
    final api = await authedApi();
    backend.on('GET', '/clients', (_) => throw http.ClientException('sin conexión'));

    await expectLater(backend.run(api.getClients), throwsA(isA<http.ClientException>()));
  });

  test('200 con JSON malformado lanza FormatException', () async {
    final api = await authedApi();
    backend.on('GET', '/clients', (_) => http.Response('{no es json', 200));

    await expectLater(backend.run(api.getClients), throwsFormatException);
  });

  // -------------------------------------------------------------------
  // FE-02: manejo global de 401 (pendiente)
  // -------------------------------------------------------------------

  test('401 en una llamada de datos: hoy solo se lanza una excepción genérica', () async {
    final api = await authedApi();
    backend.json('GET', '/activities', {"detail": "Token inválido o expirado"}, status: 401);

    await expectLater(backend.run(() => api.getActivities()),
        throwsA(predicate((e) => e.toString().contains('Error al obtener actividades'))));
  });

  test('FE-02: un 401 de la API cierra la sesión', () async {
    final api = await authedApi();
    backend.json('GET', '/activities', {"detail": "Token inválido o expirado"}, status: 401);

    try {
      await backend.run(() => api.getActivities());
    } catch (_) {}

    expect(api.auth.isAuthenticated, isFalse);
  }, skip: 'FE-02 pendiente: no hay manejo global de 401; la sesión sigue activa con un token rechazado');
}
