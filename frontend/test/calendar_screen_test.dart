// CalendarScreen (P1): carga la semana actual (lunes-domingo), muestra las
// actividades, navega entre semanas y (FE-D7-01) no controla errores.
// Sin comprobaciones visuales ni responsive (Fase I).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/calendar_screen.dart';
import 'package:http/http.dart' as http;

import 'support/test_support.dart';

String isoDate(DateTime d) => d.toIso8601String().split('T').first;

void main() {
  late FakeBackend backend;
  final today = DateTime.now();
  final monday = DateTime(today.year, today.month, today.day).subtract(Duration(days: today.weekday - 1));

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Map<String, dynamic> activityOn(DateTime day) => {
        "id": 5,
        "fecha": "${isoDate(day)}T10:30:00",
        "client_id": 1,
        "contact_id": 2,
        "activity_type_id": 1,
        "cliente": "Nebula Logística S.L.",
        "contacto": "Nora Quintana",
        "accion": "Concertar reunión",
        "comentario": "Reunión semanal",
        "resolution_status": "high",
        "products": [],
      };

  Future<void> pumpCalendar(WidgetTester tester) async {
    useDesktopSurface(tester);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const CalendarScreen()));
  }

  testWidgets('pide las actividades de la semana actual (lunes a domingo) y las muestra',
      (tester) => backend.run(() async {
            final pending = Completer<http.Response>();
            backend.on('GET', '/activities', (_) => pending.future);
            await pumpCalendar(tester);
            await tester.pump();
            expect(find.byType(CircularProgressIndicator), findsOneWidget);

            pending.complete(http.Response(jsonEncode({"activities": [activityOn(today)]}), 200,
                headers: {'content-type': 'application/json; charset=utf-8'}));
            await tester.pumpAndSettle();

            expect(backend.calls('GET', '/activities').single.url.queryParameters, {
              "date_from": isoDate(monday),
              "date_to": isoDate(monday.add(const Duration(days: 6))),
            });
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(find.textContaining('Nebula Logística S.L.'), findsWidgets);
            expect(find.textContaining('10:30'), findsWidgets);
          }));

  testWidgets('semana siguiente y anterior piden el rango desplazado 7 días', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"activities": []});
        await pumpCalendar(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.chevron_right));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.chevron_left));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.chevron_left));
        await tester.pumpAndSettle();

        final ranges = backend.calls('GET', '/activities').map((r) => r.url.queryParameters['date_from']).toList();
        expect(ranges, [
          isoDate(monday),
          isoDate(monday.add(const Duration(days: 7))),
          isoDate(monday),
          isoDate(monday.subtract(const Duration(days: 7))),
        ]);
      }));

  testWidgets('semana sin actividades: sin carga pendiente ni tarjetas', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"activities": []});
        await pumpCalendar(tester);
        await tester.pumpAndSettle();

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('Nebula'), findsNothing);
      }));

  testWidgets('FE-D7-01: si falla la carga no se queda cargando indefinidamente', (tester) => backend.run(() async {
        backend.json('GET', '/activities', {"detail": "error"}, status: 500);
        await pumpCalendar(tester);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Reintentar'), findsOneWidget);
      })); // FE-D7-01 resuelto en H.3: estado de error con Reintentar
}
