// RecorderCard (H.4, Voice V2): estados de grabación, permiso, subida a
// POST /actions/interpret-audio, errores recuperables (sin voz, servicio no
// disponible, sesión caducada), acción escrita y navegación tras confirmar.
// Sin micrófono real (FakeRecorderPlatform) ni Whisper/OpenAI (FakeBackend).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/client_detail_screen.dart';
import 'package:frontend/widgets/recorder_card.dart';
import 'package:frontend/widgets/voice/draft_review.dart';
import 'package:http/http.dart' as http;

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';
import 'support/voice_fixtures.dart';

const _idle = 'Pulsa para hablar';
const _processing = 'Transcribiendo e interpretando...';

void main() {
  late Directory tempDir;
  late FakeRecorderPlatform recorder;
  late FakeBackend backend;
  late File recording;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    tempDir = Directory.systemTemp.createTempSync('crmvoice_recorder_test');
    recording = File('${tempDir.path}/grabacion.m4a')..writeAsBytesSync([7, 7, 7, 7]);
    recorder = FakeRecorderPlatform(tempDir)..stopPath = (_) => recording.path;
  });

  tearDown(() {
    backend.expectNoUnexpectedRequests();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpRecorder(WidgetTester tester) async {
    useDesktopSurface(tester);
    recorder.install();
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const Scaffold(body: Center(child: SingleChildScrollView(child: RecorderCard())))));
  }

  Finder mic() => find.byKey(const Key('voice-mic'));

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('voice-status'))).data!;

  Future<void> tapMic(WidgetTester tester) async {
    await tester.tap(mic());
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  /// Deja avanzar la lectura REAL del fichero grabado (E/S fuera de la zona falsa).
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 50; i++) {
      await tester.pump();
      if (find.text(_processing).evaluate().isEmpty) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pumpAndSettle();
  }

  void stubInterpretAudio(Object body, {int status = 201}) =>
      backend.on('POST', '/actions/interpret-audio', (_) => jsonResponse(body, status: status));

  testWidgets('estado inicial: invita a hablar y no toca el micrófono', (tester) => backend.run(() async {
        await pumpRecorder(tester);
        expect(status(tester), _idle);
        expect(recorder.calls.where((c) => c != 'create'), isEmpty);
        expect(find.text('Escribir la acción'), findsOneWidget);
      }));

  testWidgets('pulsar graba; pulsar de nuevo para, sube el audio a /actions/interpret-audio y abre la revisión',
      (tester) => backend.run(() async {
            stubInterpretAudio({"transcript": activityDraft()["source_text"], "draft": activityDraft()});
            await pumpRecorder(tester);

            await tapMic(tester);
            expect(status(tester), startsWith('Grabando 0:00'));
            expect(recorder.calls, containsAllInOrder(['hasPermission', 'start', 'isRecording']));
            expect(find.text('Cancelar grabación'), findsOneWidget);

            await tapMic(tester);
            await settleIo(tester);

            expect(recorder.count('stop'), 1);
            final upload = backend.calls('POST', '/actions/interpret-audio').single;
            expect(upload.headers['content-type'], startsWith('multipart/form-data'));
            expect(String.fromCharCodes(upload.bodyBytes), contains('filename="grabacion.m4a"'));
            expect(backend.calls('POST', '/process-audio'), isEmpty); // nunca el flujo anterior
            expect(find.byType(DraftReview), findsOneWidget);
            expect(find.text('Revisar antes de guardar'), findsOneWidget);
          }));

  testWidgets('durante la subida no se puede volver a grabar ni subir dos veces', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        backend.on('POST', '/actions/interpret-audio', (_) => pending.future);
        await pumpRecorder(tester);

        await tapMic(tester);
        await tapMic(tester);
        for (var i = 0; i < 20 && backend.calls('POST', '/actions/interpret-audio').isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(status(tester), _processing);
        await tester.tap(mic(), warnIfMissed: false);
        await tester.pump();
        expect(recorder.count('start'), 1);
        expect(backend.calls('POST', '/actions/interpret-audio'), hasLength(1));

        pending.complete(jsonResponse({"transcript": "x", "draft": clientDraft()}, status: 201));
        await tester.pumpAndSettle();
        expect(find.byType(DraftReview), findsOneWidget);
      }));

  testWidgets('permiso denegado: error recuperable sin grabar; se puede escribir la acción', (tester) => backend.run(() async {
        recorder.permission = false;
        await pumpRecorder(tester);

        await tapMic(tester);
        expect(find.textContaining('Permiso de micrófono denegado'), findsOneWidget);
        expect(recorder.count('start'), 0);
        expect(find.text('Escribir la acción'), findsOneWidget);
      }));

  testWidgets('cancelar la grabación: descarta el audio y no sube nada', (tester) => backend.run(() async {
        await pumpRecorder(tester);
        await tapMic(tester);
        await tapText(tester, 'Cancelar grabación');
        expect(recorder.count('cancel'), 1);
        expect(status(tester), _idle);
        expect(backend.requests.where((r) => r.url.path.startsWith('/actions')), isEmpty);
      }));

  testWidgets('sin voz útil (422): conserva la transcripción y permite corregirla por texto',
      (tester) => backend.run(() async {
            stubInterpretAudio({
              "detail": "No se ha entendido nada en el audio.",
              "issues": [issueJson('missing', 'transcript', 'No se ha entendido nada en el audio.')],
              "transcript": "eh mm",
            }, status: 422);
            backend.json('POST', '/actions/interpret', clientDraft(), status: 201);
            await pumpRecorder(tester);

            await tapMic(tester);
            await tapMic(tester);
            await settleIo(tester);

            expect(find.text('No se ha entendido nada en el audio.'), findsOneWidget);
            expect(find.text('Se ha entendido: «eh mm»'), findsOneWidget);
            expect(find.text('Reintentar envío'), findsNothing); // reenviar el mismo audio no ayuda

            await tapText(tester, 'Corregir el texto');
            expect(find.text('eh mm'), findsOneWidget); // prellenado
            await tester.enterText(find.byKey(const Key('voice-text-field')),
                'Crea un cliente llamado Construcciones Mediterráneo en Alicante.');
            await tapText(tester, 'Interpretar');
            expect(lastJson(backend, 'POST', '/actions/interpret'),
                {"text": "Crea un cliente llamado Construcciones Mediterráneo en Alicante."});
            expect(find.text('Revisar antes de guardar'), findsOneWidget);
          }));

  testWidgets('servicio no disponible (503): Reintentar envío reutiliza el mismo audio', (tester) => backend.run(() async {
        var calls = 0;
        backend.on('POST', '/actions/interpret-audio', (_) {
          calls++;
          return calls == 1
              ? jsonResponse({"detail": "No se pudo transcribir el audio. Inténtalo de nuevo.", "code": "transcription_failed"},
                  status: 503)
              : jsonResponse({"transcript": "x", "draft": clientDraft()}, status: 201);
        });
        await pumpRecorder(tester);
        await tapMic(tester);
        await tapMic(tester);
        await settleIo(tester);

        expect(find.text('No se pudo transcribir el audio. Inténtalo de nuevo.'), findsOneWidget);
        await tapText(tester, 'Reintentar envío');
        final uploads = backend.calls('POST', '/actions/interpret-audio');
        expect(uploads, hasLength(2));
        for (final upload in uploads) {
          final body = String.fromCharCodes(upload.bodyBytes);
          expect(body, contains('filename="grabacion.m4a"'));
          expect(body, contains(String.fromCharCodes([7, 7, 7, 7])));
        }
        expect(recorder.count('start'), 1); // sin volver a grabar
        expect(find.byType(DraftReview), findsOneWidget);
      }));

  testWidgets('sesión caducada (401): mensaje claro', (tester) => backend.run(() async {
        stubInterpretAudio({"detail": "Token inválido o expirado"}, status: 401);
        await pumpRecorder(tester);
        await tapMic(tester);
        await tapMic(tester);
        await settleIo(tester);
        expect(find.text('Tu sesión ha caducado. Vuelve a iniciar sesión.'), findsOneWidget);
      }));

  testWidgets('orden no soportada escrita: el error se muestra y el texto se conserva', (tester) => backend.run(() async {
        backend.json('POST', '/actions/interpret', {
          "detail": "No puedo completar actividades por voz todavía.",
          "issues": [issueJson('unsupported', 'action', 'No puedo completar actividades por voz todavía.')],
        }, status: 422);
        await pumpRecorder(tester);
        await tapText(tester, 'Escribir la acción');
        await tester.enterText(find.byKey(const Key('voice-text-field')), 'Marca como hecha la reunión de ayer');
        await tapText(tester, 'Interpretar');

        expect(find.text('No puedo completar actividades por voz todavía.'), findsOneWidget);
        expect(find.text('Marca como hecha la reunión de ayer'), findsOneWidget);
        expect(find.byType(DraftReview), findsNothing);
      }));

  testWidgets('confirmar y abrir la ficha: navega a ClientDetail que carga datos frescos', (tester) => backend.run(() async {
        backend.json('POST', '/actions/interpret', clientDraft(), status: 201);
        backend.json('POST', '/actions/drf_cli/confirm', {
          "result": {"entity": "client", "ids": [1], "data": {"id": 1, "name": "Nebula Logística S.L."}},
          "draft": {...clientDraft(), "status": "executed", "confirmable": false},
        });
        backend.json('GET', '/clients/1', clientDetailJson());
        backend.json('GET', '/activities', {"activities": []});
        await pumpRecorder(tester);

        await tapText(tester, 'Escribir la acción');
        await tester.enterText(find.byKey(const Key('voice-text-field')), 'Crea el cliente Nebula');
        await tapText(tester, 'Interpretar');
        await tester.ensureVisible(find.byKey(const Key('voice-confirm')));
        await tester.tap(find.byKey(const Key('voice-confirm')));
        await tester.pumpAndSettle();
        await tapText(tester, 'Abrir ficha del cliente');

        expect(find.byType(ClientDetailScreen), findsOneWidget);
        expect(backend.calls('GET', '/clients/1'), hasLength(1));
        expect(find.text('Nebula Logística S.L.'), findsWidgets);
      }));
}
