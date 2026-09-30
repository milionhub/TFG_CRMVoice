// RecorderCard (P0): caracterización del flujo de grabación "mantener pulsado".
// Sin micrófono ni permisos reales: el plugin `record` y path_provider se
// simulan en sus MethodChannel oficiales (FakeRecorderPlatform). La subida
// del audio usa una subclase de ApiService que registra lo recibido.
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/new_activity_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/widgets/recorder_card.dart';
import 'package:provider/provider.dart';

import 'support/test_support.dart';

class UploadingApi extends ApiService {
  UploadingApi() : super(AuthProvider());

  final uploads = <({List<int> bytes, String filename})>[];
  Object? error;
  Map<String, dynamic> result = {
    "texto": "Concertar reunión con Nora",
    "accion_detectada": "Concertar reunión",
    "cliente_nombre": "Nebula Logística S.L.",
    "contacto_nombre": "Nora Quintana",
    "products_detected": [],
  };

  @override
  Future<Map<String, dynamic>> uploadAudio({required List<int> bytes, required String filename}) async {
    uploads.add((bytes: bytes, filename: filename));
    if (error != null) throw error!;
    return result;
  }
}

const _idle = 'Mantén pulsado para grabar';
const _recording = 'Grabando...';
const _processing = 'Procesando audio...';
const _deniedMessage = 'Permiso de micrófono denegado';
const _startFailed = 'No se ha podido iniciar la grabación';
const _nothingRecorded = 'No se ha grabado audio';

void main() {
  late Directory tempDir;
  late FakeRecorderPlatform recorder;
  late UploadingApi api;
  late File recording;

  setUp(() {
    cleanPreferences();
    tempDir = Directory.systemTemp.createTempSync('crmvoice_recorder_test');
    recording = File('${tempDir.path}/grabacion.m4a')..writeAsBytesSync([7, 7, 7, 7]);
    recorder = FakeRecorderPlatform(tempDir)..stopPath = (_) => recording.path;
    api = UploadingApi();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpRecorder(WidgetTester tester) async {
    recorder.install();
    await tester.pumpWidget(Provider<ApiService>.value(
      value: api,
      child: const MaterialApp(home: Scaffold(body: Center(child: RecorderCard()))),
    ));
  }

  Future<TestGesture> pressAndHold(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic_rounded)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump();
    return gesture;
  }

  /// Suelta y deja que termine el procesado: la lectura REAL del fichero
  /// (abrir/leer/cerrar) alterna E/S real y microtareas de la zona del test.
  Future<void> releaseAndProcess(WidgetTester tester, TestGesture gesture) async {
    await gesture.up();
    for (var i = 0; i < 50; i++) {
      await tester.pump();
      if (find.text(_processing).evaluate().isEmpty && find.text(_recording).evaluate().isEmpty) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  bool snackBarContains(WidgetTester tester, String text) =>
      find.descendant(of: find.byType(SnackBar), matching: find.textContaining(text)).evaluate().isNotEmpty;

  testWidgets('estado inicial: invita a mantener pulsado y no toca el micrófono', (tester) async {
    await pumpRecorder(tester);

    expect(find.text(_idle), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(recorder.calls, isEmpty);
  });

  testWidgets('pulsación larga con permiso: arranca y muestra "Grabando..."', (tester) async {
    await pumpRecorder(tester);

    final gesture = await pressAndHold(tester);

    expect(find.text(_recording), findsOneWidget);
    expect(recorder.calls, containsAllInOrder(['create', 'hasPermission', 'start', 'isRecording']));
    expect(recorder.startedPath, endsWith('.m4a'));
    expect(recorder.startedPath, startsWith(tempDir.path));

    await releaseAndProcess(tester, gesture);
  });

  testWidgets('soltar: para, sube los bytes grabados y abre la nueva actividad', (tester) async {
    await pumpRecorder(tester);
    final gesture = await pressAndHold(tester);

    await releaseAndProcess(tester, gesture);
    await tester.pumpAndSettle();

    expect(recorder.count('stop'), 1);
    expect(api.uploads.single.bytes, [7, 7, 7, 7]);
    expect(api.uploads.single.filename, 'grabacion.m4a');
    expect(find.byType(NewActivityScreen), findsOneWidget);
    expect(find.text('Nebula Logística S.L.'), findsOneWidget);
  });

  testWidgets('permiso denegado: aviso, no graba ni queda cargando; se puede reintentar', (tester) async {
    recorder.permission = false;
    await pumpRecorder(tester);

    final denied = await pressAndHold(tester);
    await denied.up();
    await tester.pump();

    expect(snackBarContains(tester, _deniedMessage), isTrue);
    expect(recorder.count('start'), 0);
    expect(find.text(_idle), findsOneWidget);
    expect(find.text(_processing), findsNothing);

    // Segundo intento, ya con permiso
    recorder.permission = true;
    final retry = await pressAndHold(tester);
    expect(find.text(_recording), findsOneWidget);
    await releaseAndProcess(tester, retry);
  });

  testWidgets('soltar antes de conceder el permiso: no graba y pide volver a pulsar', (tester) async {
    recorder.permissionCompleter = Completer<bool>();
    await pumpRecorder(tester);

    final gesture = await pressAndHold(tester);
    await gesture.up();
    await tester.pump();
    recorder.permissionCompleter!.complete(true); // el usuario acepta el diálogo tras soltar
    await tester.pump();
    await tester.pump();

    expect(recorder.count('start'), 0);
    expect(snackBarContains(tester, 'Micrófono activado'), isTrue);
    expect(find.text(_idle), findsOneWidget);
  });

  testWidgets('soltar mientras start() está pendiente: cancela y no deja grabación huérfana', (tester) async {
    recorder.startCompleter = Completer<void>();
    await pumpRecorder(tester);

    final gesture = await pressAndHold(tester);
    await gesture.up();
    await tester.pump();
    recorder.startCompleter!.complete();
    await tester.pump();
    await tester.pump();

    expect(recorder.count('cancel'), 1);
    expect(recorder.count('stop'), 0);
    expect(find.text(_idle), findsOneWidget);
    expect(api.uploads, isEmpty);
  });

  testWidgets('error al iniciar: aviso, cancela y permite reintentar', (tester) async {
    recorder.startError = PlatformException(code: 'record', message: 'micrófono ocupado');
    await pumpRecorder(tester);

    final failed = await pressAndHold(tester);
    await failed.up();
    await tester.pump();

    expect(snackBarContains(tester, _startFailed), isTrue);
    expect(recorder.count('cancel'), 1);
    expect(find.text(_idle), findsOneWidget);

    recorder.startError = null;
    final retry = await pressAndHold(tester);
    expect(find.text(_recording), findsOneWidget);
    await releaseAndProcess(tester, retry);
  });

  testWidgets('start() sin grabación efectiva (isRecording false): aviso y sin grabar', (tester) async {
    recorder.isRecordingAfterStart = false;
    await pumpRecorder(tester);

    final gesture = await pressAndHold(tester);
    await gesture.up();
    await tester.pump();

    expect(snackBarContains(tester, _startFailed), isTrue);
    expect(find.text(_recording), findsNothing);
    expect(recorder.count('stop'), 0);
  });

  for (final variant in ['stop lanza', 'stop sin ruta']) {
    testWidgets('error al parar ($variant): aviso, sin subida y sin carga infinita', (tester) async {
      if (variant == 'stop lanza') {
        recorder.stopError = PlatformException(code: 'record', message: 'fallo al parar');
      } else {
        recorder.stopPath = (_) => null;
      }
      await pumpRecorder(tester);
      final gesture = await pressAndHold(tester);

      await releaseAndProcess(tester, gesture);

      expect(snackBarContains(tester, _nothingRecorded), isTrue);
      expect(api.uploads, isEmpty);
      expect(find.text(_idle), findsOneWidget);
      expect(find.text(_processing), findsNothing);
    });
  }

  testWidgets('error al subir: aviso y vuelve a reposo (sin carga infinita)', (tester) async {
    api.error = Exception('Error al enviar audio (500)');
    await pumpRecorder(tester);
    final gesture = await pressAndHold(tester);

    await releaseAndProcess(tester, gesture);

    expect(api.uploads, hasLength(1));
    expect(snackBarContains(tester, 'Error enviando audio'), isTrue);
    expect(find.text(_processing), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(_idle), findsOneWidget);
  });

  testWidgets('si la tarjeta se desmonta con el permiso pendiente no hay setState tras dispose', (tester) async {
    recorder.permissionCompleter = Completer<bool>();
    await pumpRecorder(tester);
    final gesture = await pressAndHold(tester);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('otra pantalla'))));
    recorder.permissionCompleter!.complete(true);
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(recorder.count('start'), 0);
  });
}
