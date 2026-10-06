// H.3 · Formulario único de actividad (V2) y su uso desde Histórico y
// Calendario: validación de estado/fecha, contacto limitado al cliente,
// cuerpo V2, errores del servidor y acciones de estado (PATCH).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/crm.dart';
import 'package:frontend/screens/calendar_screen.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:frontend/widgets/crm/activity_form.dart';

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';

void main() {
  late FakeBackend backend;
  final yesterday = DateTime.now().subtract(const Duration(days: 1));

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    stubCatalogs(backend);
    backend.json('GET', '/clients', {
      "clients": [
        {"id": 1, "name": "Nebula Logística S.L."},
        {"id": 2, "name": "Orión Servicios"},
      ]
    });
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpForm(WidgetTester tester, {CrmActivity? activity}) async {
    useDesktopSurface(tester);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, hostWith((context) => openActivityForm(context, activity: activity))));
    await tapText(tester, 'abrir');
  }

  Future<void> selectType(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const Key('activity-type-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  group('formulario', () {
    testWidgets('alta manual: obligatorios, contacto del cliente elegido, completada+futura bloqueada, POST V2',
        (tester) => backend.run(() async {
              backend.json('POST', '/activities', listedActivity(at: DateTime.now()), status: 201);
              await pumpForm(tester);
              expect(find.text('Nueva actividad'), findsOneWidget);

              await tapText(tester, 'Crear actividad');
              expect(find.text('Selecciona un cliente'), findsOneWidget);
              expect(find.text('Selecciona el tipo de actividad'), findsOneWidget);

              // Cliente con buscador -> sus contactos
              await tester.tap(find.byKey(const Key('activity-client-field')));
              await tester.pumpAndSettle();
              await tester.enterText(find.widgetWithText(TextField, 'Buscar cliente...'), 'orion');
              await tester.pumpAndSettle();
              expect(find.text('Nebula Logística S.L.'), findsNothing);
              await tapText(tester, 'Orión Servicios');
              expect(backend.calls('GET', '/contacts').last.url.queryParameters, {"client_id": "2"});

              await tester.tap(find.text('Sin contacto'));
              await tester.pumpAndSettle();
              expect(find.text('Nora Quintana'), findsNothing); // es de otro cliente
              await tapText(tester, 'Otro Contacto', last: true);

              await selectType(tester, 'Realizar llamada de seguimiento');

              // Por defecto: próxima hora (futura). Completada no se permite.
              await tapText(tester, 'Completada');
              await tapText(tester, 'Crear actividad');
              expect(find.textContaining('Una actividad futura no puede estar completada'), findsOneWidget);
              expect(backend.calls('POST', '/activities'), isEmpty);

              await tapText(tester, 'Pendiente');
              await tester.enterText(find.widgetWithText(TextFormField, 'Comentario'), 'Llamar para la oferta');
              await tapText(tester, 'Crear actividad');

              final body = lastJson(backend, 'POST', '/activities');
              expect(body["client_id"], 2);
              expect(body["contact_id"], 9);
              expect(body["activity_type_id"], 2);
              expect(body["status"], 'pending');
              expect(body["comment"], 'Llamar para la oferta');
              expect(body["product_ids"], isEmpty);
              expect(body["datetime"], matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$')));
              expect(body.containsKey('fecha'), isFalse); // nada del formato anterior
              expect(find.text('Nueva actividad'), findsNothing);
            }));

    testWidgets('editar: precarga, conserva productos y envía PUT V2; el duplicado se muestra',
        (tester) => backend.run(() async {
              backend.json('PUT', '/activities/10', {
                "detail": "Ya tienes esa misma actividad (mismo cliente, contacto, tipo y hora).",
                "code": "duplicate_activity",
                "existing_id": 11,
                "issues": [
                  {
                    "code": "duplicate",
                    "field": "activity",
                    "message": "Ya tienes esa misma actividad (mismo cliente, contacto, tipo y hora).",
                    "blocking": true
                  }
                ]
              }, status: 409);
              final activity = CrmActivity.fromJson(listedActivity(at: yesterday))!;
              await pumpForm(tester, activity: activity);

              expect(find.text('Editar actividad'), findsOneWidget);
              expect(find.text('Nebula Logística S.L.'), findsOneWidget);
              expect(find.text('Nora Quintana'), findsOneWidget);
              expect(find.text('Monitor Vela 24'), findsOneWidget);
              expect(find.text('Presentar el monitor'), findsOneWidget);
              expect(find.text('Fecha pasada: quedará como pendiente vencida.'), findsOneWidget);

              await tapText(tester, 'Completada'); // pasada: permitido
              await tapText(tester, 'Guardar cambios');

              final body = lastJson(backend, 'PUT', '/activities/10');
              expect(body["status"], 'completed');
              expect(body["product_ids"], [4]);
              expect(body["contact_id"], 2);
              expect(body["datetime"], formatApiDateTime(activity.datetime!));
              expect(find.text('Ya tienes esa misma actividad (mismo cliente, contacto, tipo y hora).'), findsWidgets);
              expect(find.text('Editar actividad'), findsOneWidget);
            }));

    testWidgets('eliminar desde el formulario pide confirmación', (tester) => backend.run(() async {
          backend.json('DELETE', '/activities/10', {"success": true});
          await pumpForm(tester, activity: CrmActivity.fromJson(listedActivity(at: yesterday))!);

          await tapText(tester, 'Eliminar');
          expect(find.text('Eliminar actividad'), findsOneWidget);
          await tapText(tester, 'Eliminar', last: true);

          expect(backend.calls('DELETE', '/activities/10'), hasLength(1));
          expect(find.text('Editar actividad'), findsNothing);
        }));

    testWidgets('si no cargan los catálogos: error con Reintentar y sin guardar', (tester) => backend.run(() async {
          var calls = 0;
          backend.on('GET', '/activity-types', (_) {
            calls++;
            return calls == 1
                ? jsonResponse({"detail": "boom"}, status: 500)
                : jsonResponse({"activity_types": []});
          });
          await pumpForm(tester);
          expect(find.textContaining('Error del servidor'), findsOneWidget);
          await tapText(tester, 'Reintentar');
          expect(find.text('Tipo de actividad *'), findsOneWidget);
        }));
  });

  group('Histórico V2', () {
    Future<void> pumpHistory(WidgetTester tester) async {
      useDesktopSurface(tester);
      final auth = await loggedInAuth(backend);
      await tester.pumpWidget(appFor(auth, const HistoryScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('muestra el estado, filtra por estado en el backend y cambia el estado con PATCH',
        (tester) => backend.run(() async {
              backend.on('GET', '/activities', (request) {
                final status = request.url.queryParameters['status'];
                final all = [
                  listedActivity(id: 10, at: yesterday),
                  listedActivity(id: 11, at: yesterday, status: 'cancelled', comment: 'Anulada'),
                ];
                return jsonResponse({"activities": all.where((a) => status == null || a["status"] == status).toList()});
              });
              backend.json('PATCH', '/activities/10',
                  {"id": 10, "datetime": "2026-01-01T10:00:00", "status": "completed", "products": []});
              await pumpHistory(tester);

              expect(find.text('Pendiente · vencida'), findsOneWidget);
              expect(find.text('Cancelada'), findsOneWidget);

              await tapText(tester, 'Canceladas');
              expect(backend.calls('GET', '/activities').last.url.queryParameters['status'], 'cancelled');
              expect(find.text('Anulada'), findsOneWidget);
              expect(find.text('Presentar el monitor'), findsNothing);

              await tapText(tester, 'Todas');
              await tester.tap(find.byTooltip('Cambiar estado').first);
              await tester.pumpAndSettle();
              await tapText(tester, 'Marcar completada');
              expect(lastJson(backend, 'PATCH', '/activities/10'), {"status": "completed"});
            }));

    testWidgets('editar abre el formulario compartido; Nueva actividad también', (tester) => backend.run(() async {
          backend.json('GET', '/activities', {"activities": [listedActivity(at: yesterday)]});
          await pumpHistory(tester);

          await tester.tap(find.byTooltip('Editar'));
          await tester.pumpAndSettle();
          expect(find.byType(ActivityForm), findsOneWidget);
          expect(find.text('Editar actividad'), findsOneWidget);
          await tester.tap(find.byTooltip('Cerrar'));
          await tester.pumpAndSettle();

          await tapText(tester, 'Nueva actividad');
          expect(find.byType(ActivityForm), findsOneWidget);
        }));
  });

  group('Calendario V2', () {
    testWidgets('la tarjeta muestra el estado y abre el formulario compartido; guardar recarga la semana',
        (tester) => backend.run(() async {
              final today = DateTime.now();
              final at = DateTime(today.year, today.month, today.day, 0, 1);
              backend.json('GET', '/activities', {"activities": [listedActivity(at: at, status: 'completed')]});
              backend.json('PUT', '/activities/10', listedActivity(at: at, status: 'completed'));
              useDesktopSurface(tester);
              final auth = await loggedInAuth(backend);
              await tester.pumpWidget(appFor(auth, const CalendarScreen()));
              await tester.pumpAndSettle();

              expect(find.text('Completada'), findsOneWidget);
              await tester.tap(find.text('Concertar reunión'));
              await tester.pumpAndSettle();
              expect(find.byType(ActivityForm), findsOneWidget);
              expect(find.text('Editar actividad'), findsOneWidget);

              await tapText(tester, 'Guardar cambios');
              expect(lastJson(backend, 'PUT', '/activities/10')["status"], 'completed');
              expect(backend.calls('GET', '/activities'), hasLength(2));
            }));
  });
}
