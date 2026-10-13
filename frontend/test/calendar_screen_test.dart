// CalendarScreen: carga la semana actual (lunes-domingo), navega entre
// semanas, muestra las actividades en su día y abre el formulario compartido
// (FE-D7-01: error con Reintentar).
// I.4.2: superficie semanal única en escritorio; en móvil, selector de los
// siete días + agenda del día. Sin comentarios ni productos.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/calendar_screen.dart';
import 'package:frontend/widgets/crm/activity_form.dart';
import 'package:frontend/widgets/crm/calendar_views.dart';
import 'package:frontend/widgets/shell/app_shell.dart';
import 'package:http/http.dart' as http;

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';

String isoDate(DateTime d) => d.toIso8601String().split('T').first;

void main() {
  late FakeBackend backend;
  final today = DateTime.now();
  final monday = DateTime(today.year, today.month, today.day).subtract(Duration(days: today.weekday - 1));
  final sunday = monday.add(const Duration(days: 6));
  // Un día de esta semana distinto de hoy
  final otherDay = today.weekday == 1 ? monday.add(const Duration(days: 1)) : monday;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    stubCatalogs(backend); // para el formulario
    backend.json('GET', '/clients', {"clients": [{"id": 1, "name": "Nebula Logística S.L."}]});
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Map<String, dynamic> activityOn(DateTime day, {int id = 5}) => {
        "id": id,
        "fecha": "${isoDate(day)}T10:30:00",
        "client_id": 1,
        "contact_id": 2,
        "activity_type_id": 1,
        "cliente": "Nebula Logística S.L.",
        "contacto": "Nora Quintana",
        "accion": "Concertar reunión",
        "comentario": "Reunión semanal",
        "resolution_status": "high",
        "status": "pending",
        "products": [
          {"product_id": 4, "product_raw": "Monitor Vela 24"},
        ],
      };

  Finder dayColumn(DateTime d) => find.byKey(Key('calendar-day-${isoDate(d)}'));
  Finder dayChip(DateTime d) => find.byKey(Key('calendar-chip-${isoDate(d)}'));

  Future<void> pumpCalendar(WidgetTester tester, {Size? size}) async {
    if (size == null) {
      useDesktopSurface(tester);
    } else {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const CalendarScreen()));
  }

  group('escritorio', () {
    testWidgets('cabecera, shell y semana: pide lunes-domingo y coloca cada actividad en su día',
        (tester) => backend.run(() async {
              final pending = Completer<http.Response>();
              backend.on('GET', '/activities', (_) => pending.future);
              await pumpCalendar(tester);
              await tester.pump();
              expect(find.byType(CircularProgressIndicator), findsOneWidget);

              pending.complete(http.Response(jsonEncode({"activities": [activityOn(otherDay)]}), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'}));
              await tester.pumpAndSettle();

              expect(backend.calls('GET', '/activities').single.url.queryParameters, {
                "date_from": isoDate(monday),
                "date_to": isoDate(sunday),
              });
              expect(find.byType(CircularProgressIndicator), findsNothing);

              // Cabecera y shell
              expect(tester.widget<AppShell>(find.byType(AppShell)).currentIndex, 2);
              expect(find.descendant(of: find.byType(Sidebar), matching: find.text('Calendario')), findsOneWidget);
              expect(find.text('Organiza tu semana y no pierdas ningún seguimiento.'), findsOneWidget);
              expect(find.text('Nueva actividad'), findsOneWidget);
              expect(find.text(formatWeekRange(monday, sunday)), findsOneWidget);
              expect(find.byKey(const Key('calendar-today')), findsOneWidget);

              // Una superficie, siete días, hoy marcado
              expect(find.byType(CalendarWeekGrid), findsOneWidget);
              expect(find.byType(MobileWeekSelector), findsNothing);
              for (var i = 0; i < 7; i++) {
                expect(dayColumn(monday.add(Duration(days: i))), findsOneWidget);
              }
              expect(find.descendant(of: dayColumn(today), matching: find.text('Hoy')), findsOneWidget);
              expect(find.text('Hoy'), findsNWidgets(2)); // etiqueta del día y botón

              // Actividad en su día: hora, tipo, cliente, contacto y estado
              final column = dayColumn(otherDay);
              // Estado compacto: pendiente pasada = «Vencida» (misma regla isOverdue)
              final status = otherDay.isBefore(DateTime(today.year, today.month, today.day)) ? 'Vencida' : 'Pendiente';
              for (final text in ['10:30', 'Concertar reunión', 'Nebula Logística S.L.', 'Nora Quintana', status]) {
                expect(find.descendant(of: column, matching: find.text(text)), findsOneWidget, reason: text);
              }
              expect(find.byType(CalendarActivityBlock), findsOneWidget);

              // Sin ruido: ni «Sin actividades» por columna, ni comentario, ni productos
              expect(find.text('Sin actividades'), findsNothing);
              expect(find.byKey(const Key('calendar-week-empty')), findsNothing);
              expect(find.text('Reunión semanal'), findsNothing);
              expect(find.text('Monitor Vela 24'), findsNothing);

              // Altura compacta: no llena la ventana con dos actividades
              expect(tester.getSize(find.byType(CalendarWeekGrid)).height, inInclusiveRange(380, 440));
            }));

    testWidgets('semana siguiente, anterior y «Hoy» piden el rango correspondiente y actualizan el rango',
        (tester) => backend.run(() async {
              backend.json('GET', '/activities', {"activities": []});
              await pumpCalendar(tester);
              await tester.pumpAndSettle();

              await tester.tap(find.byIcon(Icons.chevron_right));
              await tester.pumpAndSettle();
              final nextMonday = monday.add(const Duration(days: 7));
              expect(find.text(formatWeekRange(nextMonday, nextMonday.add(const Duration(days: 6)))), findsOneWidget);
              expect(find.descendant(of: dayColumn(today), matching: find.text('Hoy')), findsNothing);

              await tester.tap(find.byIcon(Icons.chevron_left));
              await tester.pumpAndSettle();
              await tester.tap(find.byIcon(Icons.chevron_left));
              await tester.pumpAndSettle();
              await tester.tap(find.byKey(const Key('calendar-today')));
              await tester.pumpAndSettle();
              // «Hoy» en la semana actual no vuelve a pedir nada
              await tester.tap(find.byKey(const Key('calendar-today')));
              await tester.pumpAndSettle();

              final ranges = backend.calls('GET', '/activities').map((r) => r.url.queryParameters['date_from']).toList();
              expect(ranges, [
                isoDate(monday),
                isoDate(monday.add(const Duration(days: 7))),
                isoDate(monday),
                isoDate(monday.subtract(const Duration(days: 7))),
                isoDate(monday),
              ]);
              expect(find.text(formatWeekRange(monday, sunday)), findsOneWidget);
            }));

    testWidgets('semana sin actividades: una sola nota discreta, sin texto repetido por día',
        (tester) => backend.run(() async {
              backend.json('GET', '/activities', {"activities": []});
              await pumpCalendar(tester);
              await tester.pumpAndSettle();

              expect(find.byType(CircularProgressIndicator), findsNothing);
              expect(find.textContaining('Nebula'), findsNothing);
              expect(find.text('Sin actividades'), findsNothing);
              expect(find.text('No hay actividades esta semana.'), findsOneWidget);
            }));

    testWidgets('tocar una actividad abre Editar; el + de un día abre Nueva con esa fecha',
        (tester) => backend.run(() async {
              backend.json('GET', '/activities', {"activities": [activityOn(otherDay)]});
              await pumpCalendar(tester);
              await tester.pumpAndSettle();

              await tester.tap(find.byKey(const Key('calendar-activity-5')));
              await tester.pumpAndSettle();
              expect(find.text('Editar actividad'), findsOneWidget);
              await tester.tap(find.byTooltip('Cerrar'));
              await tester.pumpAndSettle();

              await tester.tap(find.descendant(of: dayColumn(otherDay), matching: find.byTooltip('Nueva actividad este día')));
              await tester.pumpAndSettle();
              final form = tester.widget<ActivityForm>(find.byType(ActivityForm));
              expect(form.activity, isNull);
              expect(form.initialDate, otherDay);
              await tester.tap(find.byTooltip('Cerrar'));
              await tester.pumpAndSettle();

              // Acción global: sin fecha propuesta
              await tester.tap(find.text('Nueva actividad'));
              await tester.pumpAndSettle();
              expect(tester.widget<ActivityForm>(find.byType(ActivityForm)).initialDate, isNull);
            }));

    testWidgets('FE-D7-01: si falla la carga no se queda cargando indefinidamente', (tester) => backend.run(() async {
          backend.json('GET', '/activities', {"detail": "error"}, status: 500);
          await pumpCalendar(tester);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));

          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.text('Reintentar'), findsOneWidget);
          expect(find.byIcon(Icons.chevron_right), findsOneWidget); // se puede seguir navegando
        })); // FE-D7-01 resuelto en H.3: estado de error con Reintentar
  });

  group('tablet', () {
    for (final (width, grid) in [(880.0, true), (720.0, false)]) {
      testWidgets('${width.toInt()} px: ${grid ? 'semana completa (columnas más estrechas)' : 'agenda'} sin desbordes',
          (tester) => backend.run(() async {
                backend.json('GET', '/activities', {
                  "activities": [
                    {
                      ...activityOn(otherDay),
                      "accion": "Realizar llamada de seguimiento",
                      "cliente": "Nebula Logística Integral de Transportes del Mediterráneo S.L.",
                      "contacto": "Nora Quintana Fernández de Villaverde",
                    }
                  ]
                });
                await pumpCalendar(tester, size: Size(width, 900));
                await tester.pumpAndSettle();

                // Un overflow haría fallar el test
                expect(find.byType(CalendarWeekGrid), grid ? findsOneWidget : findsNothing);
                expect(find.byType(MobileWeekSelector), grid ? findsNothing : findsOneWidget);
              }));
    }
  });

  group('móvil', () {
    testWidgets('selector de siete días + agenda: hoy elegido, indicadores, cambio de día, alta y edición',
        (tester) => backend.run(() async {
              final handle = tester.ensureSemantics();
              backend.json('GET', '/activities', {
                "activities": [activityOn(otherDay), activityOn(otherDay, id: 6)]
              });
              await pumpCalendar(tester, size: const Size(390, 844));
              await tester.pumpAndSettle();

              expect(find.byType(CalendarWeekGrid), findsNothing);
              expect(find.byType(MobileWeekSelector), findsOneWidget);
              for (var i = 0; i < 7; i++) {
                expect(dayChip(monday.add(Duration(days: i))), findsOneWidget);
              }

              // Hoy elegido de partida y sin actividades: nota ligera
              expect(tester.getSemantics(dayChip(today)), matchesSemantics(
                label: '${formatDayHeading(today)}, hoy, sin actividades',
                isButton: true,
                isSelected: true,
                hasSelectedState: true,
                hasTapAction: true,
              ));
              expect(find.text(formatDayHeading(today)), findsOneWidget);
              expect(find.text('No hay actividades este día.'), findsOneWidget);

              // Indicador de actividad en el día con actividades
              expect(tester.getSemantics(dayChip(otherDay)).label, '${formatDayHeading(otherDay)}, 2 actividades');

              // Cambiar de día actualiza la agenda
              await tester.tap(dayChip(otherDay));
              await tester.pumpAndSettle();
              expect(find.text(formatDayHeading(otherDay)), findsOneWidget);
              expect(find.text('No hay actividades este día.'), findsNothing);
              expect(find.byKey(const Key('calendar-activity-5')), findsOneWidget);
              expect(find.text('Nebula Logística S.L. · Nora Quintana', findRichText: true), findsNWidgets(2));
              expect(find.text('Reunión semanal'), findsNothing);
              expect(find.text('Monitor Vela 24'), findsNothing);
              expect(backend.calls('GET', '/activities'), hasLength(1)); // sin recargar

              // + del día: alta con esa fecha
              await tester.tap(find.byTooltip('Nueva actividad este día'));
              await tester.pumpAndSettle();
              expect(tester.widget<ActivityForm>(find.byType(ActivityForm)).initialDate, otherDay);
              await tester.tap(find.byTooltip('Cerrar'));
              await tester.pumpAndSettle();

              // Tocar una actividad: edición
              await tester.tap(find.byKey(const Key('calendar-activity-6')));
              await tester.pumpAndSettle();
              expect(find.text('Editar actividad'), findsOneWidget);
              handle.dispose();
            }));

    for (final width in [390.0, 360.0]) {
      testWidgets('${width.toInt()} px: sin desbordes y los siete días visibles', (tester) => backend.run(() async {
            backend.json('GET', '/activities', {
              "activities": [
                {
                  ...activityOn(today),
                  "accion": "Realizar llamada de seguimiento",
                  "cliente": "Nebula Logística Integral de Transportes del Mediterráneo S.L.",
                  "contacto": "Nora Quintana Fernández de Villaverde",
                }
              ]
            });
            await pumpCalendar(tester, size: Size(width, 800));
            await tester.pumpAndSettle();

            // Un overflow haría fallar el test
            for (var i = 0; i < 7; i++) {
              final rect = tester.getRect(dayChip(monday.add(Duration(days: i))));
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(width));
              expect(rect.width, greaterThanOrEqualTo(40), reason: 'objetivo táctil');
              expect(rect.height, greaterThanOrEqualTo(44));
            }
            expect(find.text('Nueva actividad'), findsOneWidget);
            expect(find.byKey(const Key('calendar-activity-5')), findsOneWidget);
            expect(find.text(formatWeekRange(monday, sunday)), findsOneWidget);
          }));
    }
  });
}
