// H.5.2 · Métricas de Home (GET /dashboard): valores reales, importes exactos,
// estados de carga/error/vacío y recarga al volver a Home.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/navigation.dart';
import 'package:frontend/models/crm.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/widgets/home/dashboard_panel.dart';
import 'package:http/http.dart' as http;

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';

Map<String, dynamic> dashboardJson({int pending = 3, int overdue = 1, int upcoming = 2, int upcoming7d = 1, int salesCents = 180050,
        int salesLines = 2, List<Map<String, dynamic>>? next}) =>
    {
      "now": "2026-10-15T12:00:00",
      "activities": {"pending": pending, "overdue": overdue, "upcoming": upcoming, "upcoming_7d": upcoming7d},
      "next_activities": next ??
          [
            {
              "id": 4,
              "datetime": "2026-10-16T09:00:00",
              "client_id": 1,
              "client_name": "Tecnologia Rivera SL",
              "contact_name": null,
              "activity_type": "Concertar reunión",
              "status": "pending"
            }
          ],
      "sales_month": {
        "month": "2026-10",
        "date_from": "2026-10-01",
        "date_to": "2026-10-31",
        "total_cents": salesCents,
        "line_count": salesLines
      },
    };

void main() {
  late FakeBackend backend;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  /// Panel en una pantalla con el observador de rutas real (como main.dart).
  Future<void> pumpPanel(WidgetTester tester) async {
    useDesktopSurface(tester);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(providersFor(
      auth,
      MaterialApp(
        navigatorObservers: [crmRouteObserver],
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const DashboardPanel(),
                TextButton(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const Scaffold(body: Text('otra pantalla')))),
                  child: const Text('ir'),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
  }

  String metric(WidgetTester tester, String key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)))
      .first
      .data!;

  testWidgets('muestra pendientes, vencidas, próximas y ventas del mes con importe exacto',
      (tester) => backend.run(() async {
            backend.json('GET', '/dashboard', dashboardJson());
            await pumpPanel(tester);
            await tester.pumpAndSettle();

            expect(metric(tester, 'metric-pending'), '3');
            expect(metric(tester, 'metric-overdue'), '1');
            expect(metric(tester, 'metric-upcoming'), '1');
            expect(metric(tester, 'metric-sales'), '1.800,50 €');
            expect(find.text('Tus ventas de octubre (2)'), findsOneWidget);
            expect(find.text('Próximas actividades'), findsOneWidget);
            expect(find.textContaining('Tecnologia Rivera SL'), findsOneWidget);
            expect(backend.calls('GET', '/dashboard').single.headers['Authorization'], startsWith('Bearer '));
          }));

  testWidgets('carga, error con Reintentar y vacío', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        var calls = 0;
        backend.on('GET', '/dashboard', (_) {
          calls++;
          if (calls == 1) return pending.future;
          return jsonResponse(dashboardJson(pending: 0, overdue: 0, upcoming: 0, upcoming7d: 0, salesCents: 0, salesLines: 0,
              next: []));
        });
        await pumpPanel(tester);
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        pending.complete(http.Response('error', 500));
        await tester.pumpAndSettle();
        expect(find.textContaining('No se pudo cargar el resumen'), findsOneWidget);

        await tester.tap(find.text('Reintentar'));
        await tester.pumpAndSettle();
        expect(find.text('Aún no tienes actividades pendientes ni ventas este mes.'), findsOneWidget);
        expect(metric(tester, 'metric-sales'), '0,00 €');
      }));

  testWidgets('al volver a Home se recargan las métricas', (tester) => backend.run(() async {
        var calls = 0;
        backend.on('GET', '/dashboard', (_) {
          calls++;
          return jsonResponse(dashboardJson(pending: calls));
        });
        await pumpPanel(tester);
        await tester.pumpAndSettle();
        expect(metric(tester, 'metric-pending'), '1');

        await tester.tap(find.text('ir'));
        await tester.pumpAndSettle();
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();

        expect(calls, 2);
        expect(metric(tester, 'metric-pending'), '2');
      }));

  testWidgets('Home muestra el resumen junto al micrófono', (tester) => backend.run(() async {
        FakeRecorderPlatform(Directory.systemTemp).install();
        backend.json('GET', '/ping', {"status": "ok"});
        backend.json('GET', '/dashboard', dashboardJson());
        useDesktopSurface(tester);
        final auth = await loggedInAuth(backend);
        await tester.pumpWidget(appFor(auth, const HomeScreen()));
        await tester.pumpAndSettle();
        expect(find.byType(DashboardPanel), findsOneWidget);
        expect(find.text('Tu resumen'), findsOneWidget);
        expect(find.byKey(const Key('voice-mic')), findsOneWidget);
      }));

  testWidgets('Home en móvil (360 px): resumen y micrófono sin desbordes', (tester) => backend.run(() async {
        FakeRecorderPlatform(Directory.systemTemp).install();
        backend.json('GET', '/ping', {"status": "ok"});
        backend.json('GET', '/dashboard', dashboardJson(salesCents: 123456789));
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final auth = await loggedInAuth(backend);
        await tester.pumpWidget(appFor(auth, const HomeScreen()));
        await tester.pumpAndSettle();
        expect(metric(tester, 'metric-sales'), '1.234.567,89 €');
        await tester.scrollUntilVisible(find.byKey(const Key('voice-mic')), 200);
        expect(find.byKey(const Key('voice-mic')), findsOneWidget);
      }));

  test('DashboardData tolera campos ausentes', () {
    final d = DashboardData.fromJson(const {});
    expect((d.pending, d.overdue, d.salesMonthCents), (0, 0, 0));
    expect(d.nextActivities, isEmpty);
    expect(d.isEmpty, isTrue);
  });
}
