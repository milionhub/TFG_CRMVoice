// Flujos de la app (P0): AuthScreen (validación, error, carga, login/registro,
// Google sin Google real), entrada a Home, navegación del sidebar y logout.
// Se monta CRMVoiceApp con los mismos providers que main.dart; el backend es
// FakeBackend y Google/micrófono se simulan en sus canales de plataforma.
//
// Nota de infraestructura: GoogleSignIn (singleton del plugin) encadena sus
// llamadas sobre un Future creado en la zona FakeAsync del primer testWidgets
// que lo usa; en los tests siguientes del mismo archivo esas llamadas no se
// resuelven. Por eso aquí se arranca con el auto-login de Google desactivado
// (GoogleSignIn no se toca) y los flujos que SÍ usan Google (botón y logout)
// viven cada uno en su propio archivo: google_login_ui_test.dart y
// logout_flow_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/auth_screen.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_support.dart';

const noGoogleAutoLogin = {'google_auto_login_disabled': true};

void main() {
  late FakeBackend backend;
  late FakeGoogleSignInChannel google;

  setUp(() {
    cleanPreferences(noGoogleAutoLogin);
    backend = FakeBackend();
    backend.json('GET', '/ping', {"status": "ok"});
    google = FakeGoogleSignInChannel()..install();
  });

  tearDown(() {
    backend.expectNoUnexpectedRequests();
    expect(google.calls, isEmpty, reason: 'estos flujos no deben tocar GoogleSignIn');
  });

  Future<void> pumpApp(WidgetTester tester, {AuthProvider? auth}) async {
    useDesktopSurface(tester);
    FakeRecorderPlatform(Directory.systemTemp).install(); // RecorderCard de Home
    await tester.pumpWidget(providersFor(auth ?? AuthProvider(), const CRMVoiceApp()));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  Future<void> fillLogin(WidgetTester tester, String email, String password) async {
    await tester.enterText(field('Email'), email);
    await tester.enterText(field('Password'), password);
  }

  Future<void> submit(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pump();
  }

  // -------------------------------------------------------------------
  // AuthScreen
  // -------------------------------------------------------------------

  testWidgets('sin sesión se muestra AuthScreen en modo login', (tester) => backend.run(() async {
        await pumpApp(tester);

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.text('Login'), findsOneWidget);
        expect(find.text('Sign Up'), findsOneWidget);
        expect(field('Email'), findsOneWidget);
        expect(field('Password'), findsOneWidget);
        expect(field('Nombre'), findsNothing);
        expect(find.text('Recuérdame'), findsOneWidget);
        expect(find.text('Entrar'), findsOneWidget);
      }));

  testWidgets('validación: campos vacíos, email no válido y password corta, sin llamar al backend',
      (tester) => backend.run(() async {
            await pumpApp(tester);

            await submit(tester, 'Entrar');
            expect(find.text('Introduce tu email'), findsOneWidget);
            expect(find.text('Introduce tu contraseña'), findsOneWidget);

            await fillLogin(tester, 'no-es-un-email', '123');
            await submit(tester, 'Entrar');
            expect(find.text('Email no válido'), findsOneWidget);
            expect(find.text('Mínimo 6 caracteres'), findsOneWidget);

            expect(backend.calls('POST', '/login'), isEmpty);
          }));

  testWidgets('modo registro: pide nombre y confirmación; contraseñas distintas no llegan al backend',
      (tester) => backend.run(() async {
            await pumpApp(tester);

            await tester.tap(find.text('Sign Up'));
            await tester.pumpAndSettle();

            expect(field('Nombre'), findsOneWidget);
            expect(field('Confirmar password'), findsOneWidget);
            expect(find.text('Recuérdame'), findsNothing);

            await tester.enterText(field('Nombre'), 'Ana');
            await fillLogin(tester, 'ana@crmvoice.test', 'secreta1');
            await tester.enterText(field('Confirmar password'), 'otra-distinta');
            await submit(tester, 'Crear cuenta');

            expect(find.text('Las contraseñas no coinciden'), findsOneWidget);
            expect(backend.calls('POST', '/register'), isEmpty);
          }));

  testWidgets('login fallido: aviso "Credenciales incorrectas" y se queda en AuthScreen',
      (tester) => backend.run(() async {
            backend.json('POST', '/login', {"detail": "Password incorrecto"}, status: 401);
            await pumpApp(tester);

            await fillLogin(tester, 'ana@crmvoice.test', 'secreta1');
            await submit(tester, 'Entrar');
            await tester.pumpAndSettle();

            expect(find.text('Credenciales incorrectas'), findsOneWidget);
            expect(find.byType(AuthScreen), findsOneWidget);
            expect(jsonDecode(backend.calls('POST', '/login').single.body),
                {"email": "ana@crmvoice.test", "password": "secreta1"});
          }));

  testWidgets('durante el login el botón muestra carga y queda deshabilitado', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        backend.on('POST', '/login', (_) => pending.future);
        await pumpApp(tester);

        await fillLogin(tester, 'ana@crmvoice.test', 'secreta1');
        await submit(tester, 'Entrar');

        final button = find.ancestor(of: find.byType(CircularProgressIndicator), matching: find.byType(ElevatedButton));
        expect(button, findsOneWidget);
        expect(tester.widget<ElevatedButton>(button).onPressed, isNull);

        pending.complete(http.Response('{"detail":"no"}', 401));
        await tester.pumpAndSettle();
        expect(find.text('Entrar'), findsOneWidget);
      }));

  testWidgets('login correcto entra en Home con el usuario y persiste el token (Recuérdame)',
      (tester) => backend.run(() async {
            stubSession(backend, nombre: 'Ana Test');
            await pumpApp(tester);

            await fillLogin(tester, 'ana@crmvoice.test', 'secreta1');
            await submit(tester, 'Entrar');
            await tester.pumpAndSettle();

            expect(find.byType(HomeScreen), findsOneWidget);
            expect(find.byType(AuthScreen), findsNothing);
            expect(find.text('Ana Test'), findsOneWidget);
            expect(find.text('ana@crmvoice.test'), findsOneWidget);
            expect((await SharedPreferences.getInstance()).getString('auth_token'), isNotNull);
          }));

  testWidgets('sin "Recuérdame" el token no se persiste', (tester) => backend.run(() async {
        stubSession(backend);
        await pumpApp(tester);

        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        await fillLogin(tester, 'ana@crmvoice.test', 'secreta1');
        await submit(tester, 'Entrar');
        await tester.pumpAndSettle();

        expect(find.byType(HomeScreen), findsOneWidget);
        expect((await SharedPreferences.getInstance()).getString('auth_token'), isNull);
      }));

  testWidgets('registro correcto entra en Home', (tester) => backend.run(() async {
        stubSession(backend, nombre: 'Nueva Usuaria', email: 'nueva@crmvoice.test');
        await pumpApp(tester);

        await tester.tap(find.text('Sign Up'));
        await tester.pumpAndSettle();
        await tester.enterText(field('Nombre'), 'Nueva Usuaria');
        await fillLogin(tester, 'nueva@crmvoice.test', 'secreta1');
        await tester.enterText(field('Confirmar password'), 'secreta1');
        await submit(tester, 'Crear cuenta');
        await tester.pumpAndSettle();

        expect(find.byType(HomeScreen), findsOneWidget);
        expect(jsonDecode(backend.calls('POST', '/register').single.body),
            {"nombre": "Nueva Usuaria", "email": "nueva@crmvoice.test", "password": "secreta1"});
      }));

  // -------------------------------------------------------------------
  // Home y navegación (logout: logout_flow_test.dart)
  // -------------------------------------------------------------------

  testWidgets('sesión restaurada al arrancar: Home directamente', (tester) => backend.run(() async {
        stubSession(backend, nombre: 'Ana Test');
        cleanPreferences({...noGoogleAutoLogin, 'auth_token': fakeJwt()});

        await pumpApp(tester);

        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.text('Ana Test'), findsOneWidget);
        expect(backend.calls('GET', '/me'), hasLength(1));
      }));

  testWidgets('sidebar: Histórico navega a HistoryScreen y carga las actividades', (tester) => backend.run(() async {
        stubSession(backend);
        cleanPreferences({...noGoogleAutoLogin, 'auth_token': fakeJwt()});
        backend.json('GET', '/activities', {"activities": []});
        backend.json('GET', '/clients', {"clients": []});
        backend.json('GET', '/activity-types', {"activity_types": []});
        backend.json('GET', '/products', {"products": []});
        await pumpApp(tester);

        await tester.tap(find.byIcon(Icons.menu_book_rounded));
        await tester.pumpAndSettle();

        expect(find.byType(HistoryScreen), findsOneWidget);
        expect(backend.calls('GET', '/activities'), hasLength(1));
      }));
}
