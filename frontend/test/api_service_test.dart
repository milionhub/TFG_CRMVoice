// ApiService (P0): contrato HTTP real contra un backend simulado.
// URLs, cabeceras (Bearer / Content-Type), JSON, status y errores de red.
// Sin cambios de producción: ApiService usa las funciones globales de
// package:http, que http.runWithClient redirige al MockClient de FakeBackend.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/chat_message.dart';
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

  // Voice V2 (H.4): POST /actions/interpret-audio y ciclo del borrador
  Map<String, dynamic> draftJson({int revision = 1, String status = 'open'}) => {
        "id": "abc_123",
        "action_type": "create_client",
        "status": status,
        "revision": revision,
        "source": "voice",
        "source_text": "Crea el cliente Ñandú",
        "fields": {"name": "Ñandú"},
        "issues": [],
        "confirmable": true,
        "expired": false,
        "expires_at": "2026-10-06T12:00:00",
        "result": null,
        "created_at": "2026-10-06T11:30:00",
        "updated_at": "2026-10-06T11:30:00",
      };

  test('interpretAudio: multipart "file" con Bearer a /actions/interpret-audio; transcripción y borrador', () async {
    final api = await authedApi();
    backend.json('POST', '/actions/interpret-audio',
        {"transcript": "Crea el cliente Ñandú", "draft": draftJson()}, status: 201);

    final result = await backend.run(() => api.interpretAudio(bytes: [1, 2, 3, 4], filename: 'audio_1.m4a'));

    expect(result.transcript, 'Crea el cliente Ñandú');
    expect(result.draft.id, 'abc_123');
    expect(result.draft.confirmable, isTrue);
    final request = only('POST', '/actions/interpret-audio');
    expect(request.headers['Authorization'], 'Bearer ${api.auth.token}');
    expect(request.headers['content-type'], startsWith('multipart/form-data'));
    final body = latin1.decode(request.bodyBytes);
    expect(body, contains('name="file"'));
    expect(body, contains('filename="audio_1.m4a"'));
  });

  test('interpretAudio 422 sin voz: conserva la transcripción del error; 413/503 con su mensaje', () async {
    final api = await authedApi();
    backend.json('POST', '/actions/interpret-audio', {
      "detail": "No se ha entendido nada en el audio.",
      "issues": [{"code": "missing", "field": "transcript", "message": "No se ha entendido nada en el audio.", "blocking": true}],
      "transcript": "eh",
    }, status: 422);
    await expectLater(
        backend.run(() => api.interpretAudio(bytes: [1], filename: 'a.webm')),
        throwsA(isA<ApiException>()
            .having((e) => e.body['transcript'], 'transcript', 'eh')
            .having((e) => e.message, 'message', 'No se ha entendido nada en el audio.')));

    backend.json('POST', '/actions/interpret-audio', {"detail": "El audio supera el tamaño máximo (10 MB)"}, status: 413);
    await expectLater(backend.run(() => api.interpretAudio(bytes: [1], filename: 'a.webm')),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('10 MB'))));

    backend.json('POST', '/actions/interpret-audio',
        {"detail": "No se pudo transcribir el audio. Inténtalo de nuevo.", "code": "transcription_failed"}, status: 503);
    await expectLater(backend.run(() => api.interpretAudio(bytes: [1], filename: 'a.webm')),
        throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.unavailable)));
  });

  test('borrador: PATCH con revisión y ediciones; confirm SOLO con la revisión; cancel sin cuerpo', () async {
    final api = await authedApi();
    backend.json('PATCH', '/actions/abc_123', draftJson(revision: 2));
    backend.json('POST', '/actions/abc_123/confirm', {
      "result": {"entity": "client", "ids": [9], "data": {"id": 9, "name": "Ñandú"}},
      "draft": draftJson(revision: 2, status: 'executed'),
    });
    backend.json('POST', '/actions/abc_123/cancel', draftJson(status: 'cancelled'));

    final edited = await backend.run(() => api.patchDraft('abc_123', 1, {"city": "Alicante"}));
    final confirmed = await backend.run(() => api.confirmDraft('abc_123', 2));
    final cancelled = await backend.run(() => api.cancelDraft('abc_123'));

    expect(jsonDecode(only('PATCH', '/actions/abc_123').body), {"revision": 1, "edits": {"city": "Alicante"}});
    expect(jsonDecode(only('POST', '/actions/abc_123/confirm').body), {"revision": 2});
    expect(edited.revision, 2);
    expect(confirmed.result!.entity, 'client');
    expect(confirmed.result!.clientId, 9);
    expect(cancelled.status, 'cancelled');
  });

  test('409 stale_revision: el error trae el borrador actual', () async {
    final api = await authedApi();
    backend.json('POST', '/actions/abc_123/confirm', {
      "detail": "El borrador ha cambiado: revisa la versión actual antes de confirmar.",
      "code": "stale_revision",
      "draft": draftJson(revision: 3),
      "current_revision": 3,
    }, status: 409);
    await expectLater(
        backend.run(() => api.confirmDraft('abc_123', 2)),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'stale_revision')
            .having((e) => e.body['draft']['revision'], 'draft.revision', 3)));
  });

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
  // FE-02: manejo global de 401 (H.6)
  // -------------------------------------------------------------------

  // -------------------------------------------------------------------
  // Chat V2 (G.5): POST /chat tipado
  // -------------------------------------------------------------------

  http.Response chatJson(Map<String, Object?> body, {int status = 200}) => http.Response(
      jsonEncode(body), status,
      headers: {'content-type': 'application/json; charset=utf-8'});

  Matcher chatError(ChatErrorKind kind) =>
      throwsA(isA<ChatException>().having((e) => e.kind, 'kind', kind));

  test('sendChatMessage: POST /chat con Bearer, sin conversation_id en el primer turno', () async {
    final api = await authedApi();
    backend.on('POST', '/chat', (_) => chatJson(
        {"type": "answer", "content": "Hola", "metadata": null, "conversation_id": 5}));

    final reply = await backend.run(() => api.sendChatMessage('hola'));

    final request = only('POST', '/chat');
    expect(request.url.toString(), 'http://127.0.0.1:8000/chat');
    expect(request.headers['Authorization'], 'Bearer ${api.auth.token}');
    expect(jsonDecode(request.body), {"message": "hola"});
    expect(reply.isError, isFalse);
    expect(reply.content, 'Hola');
    expect(reply.conversationId, 5);
  });

  test('sendChatMessage: envía conversation_id y decodifica UTF-8', () async {
    final api = await authedApi();
    backend.on('POST', '/chat', (_) => chatJson(
        {"type": "answer", "content": "Mañana: reunión con Peña", "metadata": null, "conversation_id": 7}));

    final reply = await backend.run(() => api.sendChatMessage('¿qué tengo?', conversationId: 7));

    expect(jsonDecode(only('POST', '/chat').body), {"message": "¿qué tengo?", "conversation_id": 7});
    expect(reply.content, 'Mañana: reunión con Peña');
  });

  test('sendChatMessage: metadata objeto (con campos null) frente a metadata null', () async {
    final api = await authedApi();
    backend.on('POST', '/chat', (_) => chatJson({
          "type": "answer",
          "content": "ok",
          "metadata": {
            "active_client": {"id": 1, "name": "Rivera"},
            "active_contact": {"id": 3, "name": "Laura", "client_id": 1},
          },
          "conversation_id": 1,
        }));
    final withContext = await backend.run(() => api.sendChatMessage('a'));
    expect(withContext.hasMetadata, isTrue);
    expect(withContext.activeClient, const ChatEntity(id: 1, name: 'Rivera'));
    expect(withContext.activeContact, const ChatEntity(id: 3, name: 'Laura'));

    backend.on('POST', '/chat', (_) => chatJson({
          "type": "answer",
          "content": "ok",
          "metadata": {"active_client": null, "active_contact": null},
          "conversation_id": 1,
        }));
    final cleared = await backend.run(() => api.sendChatMessage('b', conversationId: 1));
    expect(cleared.hasMetadata, isTrue);
    expect(cleared.activeClient, isNull);
    expect(cleared.activeContact, isNull);

    backend.on('POST', '/chat', (_) => chatJson(
        {"type": "error", "content": "El mensaje no puede estar vacío.", "metadata": null, "conversation_id": 1}));
    final noMetadata = await backend.run(() => api.sendChatMessage('c', conversationId: 1));
    expect(noMetadata.hasMetadata, isFalse);
    expect(noMetadata.isError, isTrue);
  });

  test('sendChatMessage: type error se devuelve como respuesta, no como excepción', () async {
    final api = await authedApi();
    backend.on('POST', '/chat', (_) => chatJson({
          "type": "error",
          "content": "No he podido completar la consulta.",
          "metadata": {"active_client": null, "active_contact": null},
          "conversation_id": 9,
        }));

    final reply = await backend.run(() => api.sendChatMessage('x', conversationId: 9));

    expect(reply.isError, isTrue);
    expect(reply.conversationId, 9);
  });

  for (final (status, kind) in [
    (401, ChatErrorKind.unauthorized),
    (404, ChatErrorKind.notFound),
    (422, ChatErrorKind.server),
    (500, ChatErrorKind.server),
  ]) {
    test('sendChatMessage $status → ChatErrorKind.${kind.name}', () async {
      final api = await authedApi();
      backend.json('POST', '/chat', {"detail": "detalle interno"}, status: status);

      await expectLater(backend.run(() => api.sendChatMessage('x')), chatError(kind));
    });
  }

  test('sendChatMessage: JSON malformado o sin content → server', () async {
    final api = await authedApi();
    backend.on('POST', '/chat', (_) => http.Response('<html>', 200));
    await expectLater(backend.run(() => api.sendChatMessage('x')), chatError(ChatErrorKind.server));

    backend.on('POST', '/chat', (_) => chatJson({"type": "answer", "metadata": null, "conversation_id": 1}));
    await expectLater(backend.run(() => api.sendChatMessage('x')), chatError(ChatErrorKind.server));
  });

  test('sendChatMessage: excepción del cliente HTTP → network', () async {
    final api = await authedApi();
    backend.on('POST', '/chat', (_) => throw http.ClientException('sin conexión'));

    await expectLater(backend.run(() => api.sendChatMessage('x')), chatError(ChatErrorKind.network));
  });

  testWidgets('sendChatMessage: sin respuesta en 45 s → timeout', (tester) async {
    final api = await tester.runAsync(authedApi);
    final pending = Completer<http.Response>();
    backend.on('POST', '/chat', (_) => pending.future);

    ChatException? error;
    unawaited(backend.run(() async {
      try {
        await api!.sendChatMessage('x');
      } on ChatException catch (e) {
        error = e;
      }
    }));

    await tester.pump(const Duration(seconds: 44));
    expect(error, isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(error?.kind, ChatErrorKind.timeout);
    expect(ApiService.chatTimeout, const Duration(seconds: 45));
  });

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
  });

  test('FE-02: también por las vías tipadas (CRM V2, voz y chat), y un 404/500 no cierra la sesión', () async {
    for (final call in <Future<void> Function(ApiService)>[
      (api) => api.getDashboard(),
      (api) => api.interpretAudio(bytes: [1], filename: 'a.webm'),
      (api) => api.sendChatMessage('hola'),
    ]) {
      backend = FakeBackend();
      final api = await authedApi();
      backend.json('GET', '/dashboard', {"detail": "x"}, status: 401);
      backend.json('POST', '/actions/interpret-audio', {"detail": "x"}, status: 401);
      backend.json('POST', '/chat', {"detail": "x"}, status: 401);
      try {
        await backend.run(() => call(api));
      } catch (_) {}
      await Future<void>.delayed(Duration.zero);
      expect(api.auth.isAuthenticated, isFalse);
    }

    backend = FakeBackend();
    final api = await authedApi();
    backend.json('GET', '/clients/9', {"detail": "Cliente no encontrado"}, status: 404);
    backend.json('GET', '/dashboard', {"detail": "boom"}, status: 500);
    await expectLater(backend.run(() => api.getClientDetail(9)), throwsA(isA<ApiException>()));
    await expectLater(backend.run(() => api.getDashboard()), throwsA(isA<ApiException>()));
    expect(api.auth.isAuthenticated, isTrue);
  });
}
