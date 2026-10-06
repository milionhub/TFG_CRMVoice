// AuthScreen (I.1.1): identidad, navegación Login ↔ Register, validaciones,
// error en línea y layout responsive sin overflow. Flujos completos de
// login/registro contra el backend simulado: app_flow_test.dart.
// Como en app_flow_test.dart, el auto-login de Google arranca desactivado
// para no tocar el singleton de GoogleSignIn.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/widgets/auth/auth_components.dart';
import 'package:frontend/widgets/brand/crm_voice_brand.dart';
import 'package:frontend/widgets/brand/crm_voice_wave_background.dart';

import 'support/test_support.dart';

const noGoogleAutoLogin = {'google_auto_login_disabled': true};

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences(noGoogleAutoLogin);
    backend = FakeBackend();
    backend.json('GET', '/ping', {"status": "ok"});
    FakeGoogleSignInChannel().install();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpAuth(WidgetTester tester, {Size size = const Size(1400, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    FakeRecorderPlatform(Directory.systemTemp).install();
    await tester.pumpWidget(providersFor(AuthProvider(), const CRMVoiceApp()));
    await tester.pumpAndSettle();
  }

  Finder field(String key) => find.byKey(ValueKey('auth-$key'));
  final switchMode = find.byKey(const ValueKey('auth-switch-mode'));

  testWidgets('login: marca CRMVoice, eslogan, cabecera y campos', (tester) => backend.run(() async {
        await pumpAuth(tester);

        expect(find.byType(CrmVoiceWordmark), findsOneWidget);
        expect(find.text('VOICE CRM'), findsNothing);
        expect(find.text('Tu CRM. Ahora también te escucha.'), findsOneWidget);
        expect(find.text('Bienvenido de nuevo'), findsOneWidget);
        expect(find.text('Accede a tu CRM y continúa donde lo dejaste.'), findsOneWidget);
        expect(find.text('Correo electrónico'), findsOneWidget);
        expect(find.text('Contraseña'), findsOneWidget);
        expect(field('email'), findsOneWidget);
        expect(field('password'), findsOneWidget);
        expect(find.text('Recuérdame'), findsOneWidget);
        expect(find.text('Entrar'), findsOneWidget);
        expect(find.text('o continúa con'), findsOneWidget);
        expect(find.text('Continuar con Google'), findsOneWidget);
        expect(find.text('¿Aún no tienes cuenta?'), findsOneWidget);
      }));

  testWidgets('Login ↔ Register: cambia cabecera, campos y CTA y limpia el formulario',
      (tester) => backend.run(() async {
            await pumpAuth(tester);
            await tester.enterText(field('email'), 'ana@crmvoice.test');

            await tester.tap(switchMode);
            await tester.pumpAndSettle();

            expect(find.text('Crea tu cuenta'), findsOneWidget);
            expect(find.text('Empieza a gestionar tu CRM de una forma más natural.'), findsOneWidget);
            expect(field('name'), findsOneWidget);
            expect(field('confirm-password'), findsOneWidget);
            expect(find.text('Recuérdame'), findsNothing);
            expect(find.text('Crear cuenta'), findsOneWidget); // CTA
            expect(find.text('¿Ya tienes cuenta?'), findsOneWidget);
            expect(find.text('Continuar con Google'), findsOneWidget);
            expect(find.text('ana@crmvoice.test'), findsNothing);

            await tester.ensureVisible(find.text('Inicia sesión'));
            await tester.tap(find.text('Inicia sesión'));
            await tester.pumpAndSettle();

            expect(find.text('Bienvenido de nuevo'), findsOneWidget);
            expect(field('name'), findsNothing);
            expect(field('confirm-password'), findsNothing);
          }));

  testWidgets('registro: campos obligatorios validados sin llamar al backend', (tester) => backend.run(() async {
        await pumpAuth(tester);
        await tester.tap(switchMode);
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Crear cuenta'));
        await tester.tap(find.text('Crear cuenta'));
        await tester.pump();

        expect(find.text('Introduce tu nombre'), findsOneWidget);
        expect(find.text('Introduce tu email'), findsOneWidget);
        expect(find.text('Introduce tu contraseña'), findsOneWidget);
        expect(backend.calls('POST', '/register'), isEmpty);
      }));

  testWidgets('mostrar/ocultar contraseña', (tester) => backend.run(() async {
        await pumpAuth(tester);
        EditableText editable() => tester.widget<EditableText>(
            find.descendant(of: field('password'), matching: find.byType(EditableText)));

        expect(editable().obscureText, isTrue);
        await tester.tap(find.byTooltip('Mostrar contraseña'));
        await tester.pump();
        expect(editable().obscureText, isFalse);
        await tester.tap(find.byTooltip('Ocultar contraseña'));
        await tester.pump();
        expect(editable().obscureText, isTrue);
      }));

  testWidgets('error del backend en línea; se limpia al editar y al cambiar de modo',
      (tester) => backend.run(() async {
            backend.json('POST', '/login', {"detail": "Password incorrecto"}, status: 401);
            await pumpAuth(tester);

            await tester.enterText(field('email'), 'ana@crmvoice.test');
            await tester.enterText(field('password'), 'secreta1');
            await tester.testTextInput.receiveAction(TextInputAction.done); // Enter envía
            await tester.pumpAndSettle();

            expect(find.byType(AuthErrorBanner), findsOneWidget);
            expect(find.text('Credenciales incorrectas'), findsOneWidget);
            expect(find.byIcon(Icons.error_outline), findsOneWidget); // no solo color

            await tester.enterText(field('password'), 'secreta2');
            await tester.pump();
            expect(find.byType(AuthErrorBanner), findsNothing);

            await tester.testTextInput.receiveAction(TextInputAction.done);
            await tester.pumpAndSettle();
            expect(find.byType(AuthErrorBanner), findsOneWidget);

            await tester.ensureVisible(switchMode);
            await tester.tap(switchMode);
            await tester.pumpAndSettle();
            expect(find.byType(AuthErrorBanner), findsNothing);
          }));

  testWidgets('registro fallido muestra un error propio del registro', (tester) => backend.run(() async {
        backend.json('POST', '/register', {"detail": "Email ya registrado"}, status: 400);
        await pumpAuth(tester);
        await tester.tap(switchMode);
        await tester.pumpAndSettle();

        await tester.enterText(field('name'), 'Ana');
        await tester.enterText(field('email'), 'ana@crmvoice.test');
        await tester.enterText(field('password'), 'secreta1');
        await tester.enterText(field('confirm-password'), 'secreta1');
        await tester.ensureVisible(find.text('Crear cuenta'));
        await tester.tap(find.text('Crear cuenta'));
        await tester.pumpAndSettle();

        expect(find.text('No se pudo crear la cuenta. Revisa los datos e inténtalo de nuevo.'),
            findsOneWidget);
      }));

  group('responsive sin overflow', () {
    const sizes = {
      'desktop 1440x900': (Size(1440, 900), CvWaveDensity.desktop),
      'tablet 768x1024': (Size(768, 1024), CvWaveDensity.tablet),
      'tablet apaisada 1024x768': (Size(1024, 768), CvWaveDensity.desktop),
      'móvil 390x844': (Size(390, 844), CvWaveDensity.mobile),
      'móvil pequeño 320x568': (Size(320, 568), CvWaveDensity.mobile),
    };

    sizes.forEach((name, spec) {
      final (size, density) = spec;
      testWidgets('$name: login y registro', (tester) => backend.run(() async {
            await pumpAuth(tester, size: size);
            expect(tester.takeException(), isNull);

            // Fondo de ondas: densidad propia del tamaño y sin afectar al layout
            final background = find.byType(CrmVoiceWaveBackground);
            expect(tester.widget<CrmVoiceWaveBackground>(background).density, density);
            expect(tester.getSize(background), size);

            // Errores de validación visibles (alto máximo del formulario)
            await tester.ensureVisible(find.text('Entrar'));
            await tester.tap(find.text('Entrar'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);

            await tester.ensureVisible(switchMode);
            await tester.tap(switchMode);
            await tester.pumpAndSettle();
            expect(find.text('Crea tu cuenta'), findsOneWidget);
            expect(tester.takeException(), isNull);

            // El CTA es alcanzable con scroll y ocupa el ancho del formulario
            await tester.ensureVisible(find.text('Crear cuenta'));
            final cta = tester.getSize(find.byType(AuthPrimaryButton));
            expect(cta.height, greaterThanOrEqualTo(48));
            expect(cta.width, lessThanOrEqualTo(size.width - 32));
          }));
    });

    testWidgets('móvil: formulario sin tarjeta y con margen lateral cómodo', (tester) => backend.run(() async {
          await pumpAuth(tester, size: const Size(390, 844));
          final emailRect = tester.getRect(field('email'));
          expect(emailRect.left, greaterThanOrEqualTo(16));
          expect(390 - emailRect.right, greaterThanOrEqualTo(16));
          // Aprovecha el ancho: el campo ocupa casi todo el ancho disponible
          expect(emailRect.width, greaterThan(390 - 2 * 24));
        }));
  });
}
