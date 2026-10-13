// I.2 · Shell (barra lateral completa/compacta, menú móvil) e Inicio
// (saludo → voz → resumen → próximas actividades) en escritorio, tablet y
// móvil. El logout real (Google incluido) se prueba en logout_flow_test.dart
// y la navegación sin pilas acumuladas en desktop/mobile_navigation_test.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/clients_screen.dart';
import 'package:frontend/screens/home_content.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/widgets/brand/crm_voice_brand.dart';
import 'package:frontend/widgets/shell/app_shell.dart';
import 'package:frontend/widgets/ui/cv_components.dart';

import 'support/test_support.dart';

Map<String, dynamic> _dashboard() => {
      "now": "2026-10-15T12:00:00",
      "activities": {"pending": 4, "overdue": 2, "upcoming": 3, "upcoming_7d": 3},
      "next_activities": [
        {
          "id": 4,
          "datetime": "2099-10-16T09:00:00",
          "client_id": 1,
          "client_name": "Tecnologia Rivera SL",
          "activity_type": "Concertar reunión",
          "status": "pending"
        },
        {
          "id": 5,
          "datetime": "2099-10-17T12:30:00",
          "client_id": 1,
          "client_name": "Tecnologia Rivera SL",
          "activity_type": "Enviar oferta",
          "status": "pending"
        },
      ],
      "sales_month": {"month": "2026-10", "total_cents": 1234567, "line_count": 3},
    };

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    FakeRecorderPlatform(Directory.systemTemp).install();
    backend.json('GET', '/ping', {"status": "ok"});
    backend.json('GET', '/dashboard', _dashboard());
    backend.json('GET', '/clients', {"clients": []});
    backend.json('GET', '/activities', {"activities": []});
    backend.json('GET', '/activity-types', {"activity_types": []});
    backend.json('GET', '/products', {"products": []});
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const HomeScreen()));
    await tester.pumpAndSettle();
  }

  /// Scroll del contenido (la barra lateral tiene el suyo).
  final page = find.descendant(of: find.byType(CvPageBody), matching: find.byType(Scrollable)).first;

  Finder inSidebar(Finder f) => find.descendant(of: find.byType(Sidebar), matching: f);

  ShellNavItem navItem(WidgetTester tester, String label, {Finder? scope}) => tester
      .widgetList<ShellNavItem>(find.descendant(of: scope ?? find.byType(Sidebar), matching: find.byType(ShellNavItem)))
      .firstWhere((i) => i.destination.label == label);

  group('escritorio', () {
    testWidgets('barra lateral: marca, secciones, Inicio activo y usuario con cerrar sesión',
        (tester) => backend.run(() async {
              await pumpHome(tester, const Size(1440, 900));

              expect(tester.getSize(find.byType(Sidebar)).width, 248);
              expect(inSidebar(find.byType(CrmVoiceWordmark)), findsOneWidget);
              for (final d in shellDestinations) {
                expect(inSidebar(find.text(d.label)), findsOneWidget);
              }
              expect(navItem(tester, 'Inicio').selected, isTrue);
              expect(navItem(tester, 'Clientes').selected, isFalse);

              // Usuario integrado al pie (sin la cápsula flotante anterior)
              expect(inSidebar(find.text('Ana Test')), findsOneWidget);
              expect(inSidebar(find.text('ana@crmvoice.test')), findsOneWidget);
              expect(inSidebar(find.byTooltip('Cerrar sesión')), findsOneWidget);
              expect(find.text('Ana Test'), findsOneWidget);
            }));

    testWidgets('Inicio: saludo, voz, resumen y próximas actividades, en ese orden',
        (tester) => backend.run(() async {
              await pumpHome(tester, const Size(1440, 900));

              expect(find.textContaining(', Ana 👋'), findsOneWidget);
              expect(find.text('Esto es lo que ocurre hoy en tu CRM.'), findsOneWidget);
              expect(find.text('¿Qué quieres registrar?'), findsOneWidget);
              expect(find.text('Escribir la acción'), findsOneWidget);

              double top(Finder f) => tester.getTopLeft(f).dy;
              final greeting = top(find.byKey(const Key('home-greeting')));
              final voice = top(find.byKey(const Key('voice-hero')));
              final summary = top(find.text('Tu resumen'));
              final upcoming = top(find.text('Próximas actividades'));
              expect(greeting, lessThan(voice));
              expect(voice, lessThan(summary), reason: 'la voz va antes que el resumen');
              expect(summary, lessThan(upcoming));

              // Métricas reales y en una fila
              final metrics = ['metric-pending', 'metric-overdue', 'metric-upcoming', 'metric-sales'];
              final rows = metrics.map((k) => top(find.byKey(Key(k)))).toSet();
              expect(rows, hasLength(1));
              expect(find.descendant(of: find.byKey(const Key('metric-sales')), matching: find.text('12.345,67 €')),
                  findsOneWidget);
              expect(find.text('Concertar reunión'), findsOneWidget);
              expect(find.text('Enviar oferta'), findsOneWidget);
            }));

    testWidgets('el contenido no se estira en monitores grandes', (tester) => backend.run(() async {
          await pumpHome(tester, const Size(2560, 1440));
          expect(tester.getSize(find.byKey(const Key('voice-hero'))).width, lessThanOrEqualTo(1080));
          expect(tester.takeException(), isNull);
        }));

    testWidgets('«Escribir la acción» sigue abriendo el diálogo desde el Inicio', (tester) => backend.run(() async {
          await pumpHome(tester, const Size(1440, 900));
          await tester.tap(find.text('Escribir la acción'));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('voice-text-field')), findsOneWidget);
        }));
  });

  group('tablet', () {
    testWidgets('barra lateral compacta: solo iconos con tooltip y navegación que sustituye la pila',
        (tester) => backend.run(() async {
              await pumpHome(tester, const Size(900, 1100));

              expect(tester.getSize(find.byType(Sidebar)).width, 76);
              expect(inSidebar(find.text('Clientes')), findsNothing);
              expect(inSidebar(find.byType(CrmVoiceMark)), findsOneWidget);
              expect(inSidebar(find.byTooltip('Clientes')), findsOneWidget);
              expect(inSidebar(find.byTooltip('Cerrar sesión')), findsOneWidget);
              expect(navItem(tester, 'Inicio').selected, isTrue);

              await tester.tap(inSidebar(find.byTooltip('Clientes')));
              await tester.pumpAndSettle();
              expect(find.byType(ClientsScreen), findsOneWidget);
              expect(tester.state<NavigatorState>(find.byType(Navigator).first).canPop(), isFalse);
              expect(navItem(tester, 'Clientes').selected, isTrue);
            }));

    testWidgets('resumen en 2x2', (tester) => backend.run(() async {
          await pumpHome(tester, const Size(820, 1180));
          double top(String k) => tester.getTopLeft(find.byKey(Key(k))).dy;
          expect(top('metric-pending'), top('metric-overdue'));
          expect(top('metric-upcoming'), greaterThan(top('metric-pending')));
          expect(top('metric-upcoming'), top('metric-sales'));
        }));
  });

  group('móvil', () {
    testWidgets('cabecera con marca y menú; menú con secciones, sección activa y usuario',
        (tester) => backend.run(() async {
              await pumpHome(tester, const Size(390, 844));

              expect(find.byType(Sidebar), findsNothing);
              expect(find.descendant(of: find.byType(AppBar), matching: find.byType(CrmVoiceWordmark)), findsOneWidget);

              await tester.tap(find.byTooltip('Abrir menú'));
              await tester.pumpAndSettle();

              final drawer = find.byType(Drawer);
              expect(drawer, findsOneWidget);
              for (final d in shellDestinations) {
                expect(find.descendant(of: drawer, matching: find.text(d.label)), findsOneWidget);
              }
              expect(navItem(tester, 'Inicio', scope: drawer).selected, isTrue);
              expect(find.descendant(of: drawer, matching: find.text('Ana Test')), findsOneWidget);
              expect(find.descendant(of: drawer, matching: find.text('Cerrar sesión')), findsOneWidget);
              // Objetivos táctiles de al menos 48 px
              final item = find.descendant(of: drawer, matching: find.byType(ShellNavItem)).first;
              expect(tester.getSize(item).height, greaterThanOrEqualTo(48));
            }));

    testWidgets('Inicio: misma jerarquía, voz a todo el ancho y resumen 2x2', (tester) => backend.run(() async {
          await pumpHome(tester, const Size(390, 844));

          double top(Finder f) => tester.getTopLeft(f).dy;
          expect(top(find.byKey(const Key('home-greeting'))), lessThan(top(find.byKey(const Key('voice-hero')))));
          final hero = tester.getRect(find.byKey(const Key('voice-hero')));
          expect(hero.left, 20);
          expect(390 - hero.right, 20);

          await tester.scrollUntilVisible(find.text('Próximas actividades'), 200, scrollable: page);
          expect(top(find.text('Tu resumen')), lessThan(top(find.text('Próximas actividades'))));
          double metric(String k) => top(find.byKey(Key(k)));
          expect(metric('metric-pending'), metric('metric-overdue'));
          expect(metric('metric-upcoming'), greaterThan(metric('metric-pending')));
        }));
  });

  group('transición entre secciones', () {
    Finder ancestorsOf(Finder of, Type type) => find.ancestor(of: of, matching: find.byType(type));

    testWidgets('escritorio: la barra lateral no se anima; solo el contenido hace un fundido corto',
        (tester) => backend.run(() async {
              await pumpHome(tester, const Size(1440, 900));
              await tester.tap(inSidebar(find.text('Clientes')));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 60));

              // A mitad de transición: la ruta nueva no envuelve la pantalla en
              // ninguna transición (sin zoom, sin deslizamiento, sin velo)
              final route = ModalRoute.of(tester.element(find.byType(ClientsScreen)))!;
              expect(route, isA<SectionRoute>());
              final newSidebar = find.descendant(of: find.byType(ClientsScreen), matching: find.byType(Sidebar));
              expect(ancestorsOf(newSidebar, FadeTransition), findsNothing);
              expect(ancestorsOf(newSidebar, SlideTransition), findsNothing);
              expect(ancestorsOf(newSidebar, ScaleTransition), findsNothing);

              final content = find.byType(ClientsContent);
              final fade = tester.widget<FadeTransition>(ancestorsOf(content, FadeTransition).first);
              expect(fade.opacity.value, inExclusiveRange(0, 1));

              await tester.pumpAndSettle();
              expect(tester.widget<FadeTransition>(ancestorsOf(content, FadeTransition).first).opacity.value, 1);
              expect(tester.state<NavigatorState>(find.byType(Navigator).first).canPop(), isFalse);
            }));

    testWidgets('móvil: el menú se cierra y el destino aparece con un fundido, sin deslizamientos',
        (tester) => backend.run(() async {
              await pumpHome(tester, const Size(390, 844));
              await tester.tap(find.byTooltip('Abrir menú'));
              await tester.pumpAndSettle();
              await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Clientes')));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 30));

              // Primero solo se cierra el menú; el destino aún no se ve
              final screenFade = tester.widget<FadeTransition>(ancestorsOf(find.byType(ClientsScreen), FadeTransition).first);
              expect(screenFade.opacity.value, 0);
              expect(find.byType(Drawer), findsOneWidget);
              expect(ancestorsOf(find.byType(ClientsScreen), SlideTransition), findsNothing);

              await tester.pumpAndSettle();
              expect(find.byType(Drawer), findsNothing);
              expect(find.byType(ClientsScreen), findsOneWidget);
              expect(tester.state<NavigatorState>(find.byType(Navigator).first).canPop(), isFalse);
            }));
  });

  group('sin desbordes', () {
    const sizes = {
      'escritorio grande 1920x1080': Size(1920, 1080),
      'portátil 1366x768': Size(1366, 768),
      'tablet apaisada 1024x768': Size(1024, 768),
      'tablet 820x1180': Size(820, 1180),
      'móvil 390x844': Size(390, 844),
      'móvil pequeño 360x640': Size(360, 640),
    };
    sizes.forEach((name, size) {
      testWidgets(name, (tester) => backend.run(() async {
            await pumpHome(tester, size);
            expect(tester.takeException(), isNull);
            await tester.scrollUntilVisible(find.text('Enviar oferta'), 300, scrollable: page);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }));
    });
  });

  test('saludo según la hora', () {
    expect(greetingFor(DateTime(2026, 10, 6, 8)), 'Buenos días');
    expect(greetingFor(DateTime(2026, 10, 6, 16)), 'Buenas tardes');
    expect(greetingFor(DateTime(2026, 10, 6, 23)), 'Buenas noches');
    expect(greetingFor(DateTime(2026, 10, 6, 3)), 'Buenas noches');
  });
}
