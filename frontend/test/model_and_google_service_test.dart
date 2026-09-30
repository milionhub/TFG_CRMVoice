// Modelo Activity y GoogleAuthService (P1).
//
// Activity.fromJson y ActivityProvider solo se registran en main.dart: ninguna
// pantalla los usa hoy (History/Calendar trabajan con los Map de ApiService).
// GoogleAuthService: solo lógica propia; el plugin se simula en su canal.
// La rama web (kIsWeb, botón oficial, GOOGLE_CLIENT_ID vacío) no es
// alcanzable desde flutter test (kIsWeb es constante false en la VM).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/activity.dart';
import 'package:frontend/services/google_auth_service.dart';

import 'support/test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Activity.fromJson', () {
    final json = {
      "id": 3,
      "fecha": "2026-10-01T10:30:00",
      "cliente": "Nebula Logística S.L.",
      "accion": "Concertar reunión",
      "comentario": "Presentar el monitor",
      "resolution_status": "high",
      "products": [{"product_id": 4, "product_raw": "Monitor Vela 24"}],
    };

    test('mapea los campos del contrato de GET /activities', () {
      final activity = Activity.fromJson(json);

      expect(activity.id, 3);
      expect(activity.fecha, "2026-10-01T10:30:00");
      expect(activity.cliente, "Nebula Logística S.L.");
      expect(activity.accion, "Concertar reunión");
      expect(activity.comentario, "Presentar el monitor");
      expect(activity.resolutionStatus, "high");
    });

    test('fecha, cliente y acción pueden ser null; resolution_status ausente es "auto"', () {
      final activity = Activity.fromJson({
        "id": 1, "fecha": null, "cliente": null, "accion": null, "comentario": "x", "resolution_status": null,
      });

      expect(activity.fecha, isNull);
      expect(activity.cliente, isNull);
      expect(activity.accion, isNull);
      expect(activity.resolutionStatus, "auto");
    });

    test('FE-D7-04: un comentario null del backend no rompe el parseo', () {
      expect(() => Activity.fromJson({...json, "comentario": null}), returnsNormally);
    }, skip: 'FE-D7-04: comentario es String no nullable; el backend puede devolver null (modelo hoy sin uso)');
  });

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
