// H.4 · Revisión de borradores (Voice V2): las cuatro acciones, coincidencias
// aproximadas, ambigüedad con candidatos, ediciones tipadas por PATCH con la
// revisión, confirmación SOLO con {revision}, reintento idempotente,
// borrador obsoleto/caducado, reinterpretación y cancelación.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/voice/draft_review.dart';
import 'package:http/http.dart' as http;

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';
import 'support/voice_fixtures.dart';

void main() {
  late FakeBackend backend;
  late ReviewHost host;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
    host = ReviewHost();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpReview(WidgetTester tester, Map<String, dynamic> draft) async {
    useDesktopSurface(tester);
    final auth = await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, host.build(draft)));
    await tapText(tester, 'abrir');
  }

  Finder confirmButton() => find.byKey(const Key('voice-confirm'));
  bool confirmEnabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(confirmButton()).enabled;

  Future<void> tapConfirm(WidgetTester tester) async {
    await tester.ensureVisible(confirmButton());
    await tester.tap(confirmButton());
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> executed(Map<String, dynamic> draft, Map<String, dynamic> result) =>
      {...draft, "status": "executed", "confirmable": false, "result": result};

  group('actividad (ejemplo 1)', () {
    testWidgets('muestra transcripción literal, nombres oficiales, lo dicho y el tipo de coincidencia',
        (tester) => backend.run(() async {
              await pumpReview(tester, activityDraft());

              expect(find.text('Nueva actividad · revisión'), findsOneWidget);
              expect(find.text('«Mañana a las diez tengo que llamar a Ana de Rivera para hablar del portátil Luna 13.»'),
                  findsOneWidget);
              expect(find.text('Construcciones Rivera S.L.'), findsOneWidget);
              expect(find.text('Dijiste «Rivera»'), findsOneWidget);
              expect(find.text('Ana Martínez'), findsOneWidget);
              expect(find.text('Coincidencia aproximada'), findsNWidgets(2));
              expect(find.text('Realizar llamada de seguimiento'), findsOneWidget);
              expect(find.text('Coincidencia exacta'), findsNWidgets(2)); // tipo + producto
              expect(find.text('10:00'), findsOneWidget);
              expect(find.text('Portátil Luna 13'), findsOneWidget);
              expect(find.text('Has dicho «Rivera»: Construcciones Rivera S.L.'), findsOneWidget); // aviso no bloqueante
              expect(find.text('Listo para confirmar. Revisa los datos antes de guardar.'), findsOneWidget);
              expect(confirmEnabled(tester), isTrue);
            }));

    testWidgets('confirmar envía SOLO {revision}; doble clic = una petición; éxito con enlaces',
        (tester) => backend.run(() async {
              final pending = Completer<http.Response>();
              backend.on('POST', '/actions/drf_act/confirm', (_) => pending.future);
              await pumpReview(tester, activityDraft());

              await tester.ensureVisible(confirmButton());
              await tester.tap(confirmButton());
              await tester.pump();
              expect(find.text('Guardando...'), findsOneWidget);
              await tester.tap(confirmButton(), warnIfMissed: false);
              await tester.pump();

              pending.complete(jsonResponse({
                "result": {
                  "entity": "activity",
                  "ids": [99],
                  "data": {"id": 99, "client_id": 1, "client_name": "Construcciones Rivera S.L.", "activity_type": "Realizar llamada de seguimiento", "datetime": "${isoDay(tomorrow)}T10:00:00"}
                },
                "draft": executed(activityDraft(), {"entity": "activity", "ids": [99]}),
              }));
              await tester.pumpAndSettle();

              expect(backend.calls('POST', '/actions/drf_act/confirm'), hasLength(1));
              expect(lastJson(backend, 'POST', '/actions/drf_act/confirm'), {"revision": 1});
              expect(find.text('Actividad creada'), findsOneWidget);
              expect(find.text('Ver en Actividades'), findsOneWidget);
              await tapText(tester, 'Abrir ficha del cliente');
              expect(host.outcome!.target, VoiceNavTarget.clientDetail);
              expect(host.outcome!.result.clientId, 1);
            }));

    testWidgets('producto ambiguo: candidatos del servidor; elegir uno -> PATCH product_ids con la revisión',
        (tester) => backend.run(() async {
              final ambiguous = activityDraft(products: [
                {
                  "id": null,
                  "label": null,
                  "said": "Luna",
                  "match": null,
                  "problem": "ambiguous",
                  "candidates": [
                    {"id": 4, "label": "Portátil Luna 13"},
                    {"id": 6, "label": "Portátil Luna 15"}
                  ]
                }
              ], issues: [
                issueJson('ambiguous', 'products[0]', 'Hay varios productos que encajan con «Luna»: elige uno.')
              ]);
              backend.json('PATCH', '/actions/drf_act', activityDraft(revision: 2));
              await pumpReview(tester, ambiguous);

              expect(find.text('Ambiguo: elige uno'), findsOneWidget);
              expect(find.textContaining('Para poder confirmar'), findsOneWidget);
              expect(confirmEnabled(tester), isFalse);

              await tapText(tester, 'Portátil Luna 15');
              expect(lastJson(backend, 'PATCH', '/actions/drf_act'), {
                "revision": 1,
                "edits": {"product_ids": [6]}
              });
              expect(confirmEnabled(tester), isTrue);
            }));

    testWidgets('edición tipada de hora y estado; 409 stale muestra la versión actual del servidor',
        (tester) => backend.run(() async {
              var patches = 0;
              backend.on('PATCH', '/actions/drf_act', (request) {
                patches++;
                if (patches == 1) {
                  return jsonResponse({
                    ...activityDraft(revision: 2),
                    "fields": {...activityDraft()["fields"], "status": "completed"},
                  });
                }
                return jsonResponse({
                  "detail": "El borrador ha cambiado: revisa la versión actual.",
                  "code": "stale_revision",
                  "draft": activityDraft(revision: 5),
                  "current_revision": 5,
                }, status: 409);
              });
              await pumpReview(tester, activityDraft());

              await tapText(tester, 'Completada');
              expect(lastJson(backend, 'PATCH', '/actions/drf_act'), {"revision": 1, "edits": {"status": "completed"}});

              // Segunda edición con revisión 2 -> el servidor ya va por la 5
              await tester.tap(find.byTooltip('Quitar contacto'));
              await tester.pumpAndSettle();
              expect(lastJson(backend, 'PATCH', '/actions/drf_act'), {"revision": 2, "edits": {"contact_id": null}});
              expect(find.text('El borrador ha cambiado: revisa la versión actual.'), findsOneWidget);

              backend.json('POST', '/actions/drf_act/confirm', {
                "result": {"entity": "activity", "ids": [1], "data": {"client_id": 1}},
                "draft": executed(activityDraft(revision: 5), {"entity": "activity", "ids": [1]}),
              });
              await tapConfirm(tester);
              expect(lastJson(backend, 'POST', '/actions/drf_act/confirm'), {"revision": 5});
            }));
  });

  group('cliente (ejemplo 2)', () {
    testWidgets('editar un campo de texto -> PATCH con ese campo; confirmar', (tester) => backend.run(() async {
          backend.json('PATCH', '/actions/drf_cli', clientDraft(revision: 2, province: 'Alicante'));
          backend.json('POST', '/actions/drf_cli/confirm', {
            "result": {"entity": "client", "ids": [30], "data": {"id": 30, "name": "Construcciones Mediterráneo"}},
            "draft": executed(clientDraft(revision: 2), {"entity": "client", "ids": [30]}),
          });
          await pumpReview(tester, clientDraft());

          expect(find.text('Nuevo cliente · revisión'), findsOneWidget);
          expect(find.text('Construcciones Mediterráneo'), findsOneWidget);
          await tester.tap(find.byTooltip('Cambiar provincia'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).last, 'Alicante');
          await tapText(tester, 'Aplicar');
          expect(lastJson(backend, 'PATCH', '/actions/drf_cli'), {"revision": 1, "edits": {"province": "Alicante"}});
          expect(find.text('Alicante'), findsNWidgets(2));

          await tapConfirm(tester);
          expect(lastJson(backend, 'POST', '/actions/drf_cli/confirm'), {"revision": 2});
          expect(find.text('Cliente creado'), findsOneWidget);
          await tapText(tester, 'Abrir ficha del cliente');
          expect(host.outcome!.result.clientId, 30);
        }));
  });

  group('contacto (ejemplo 3) con cliente ambiguo', () {
    testWidgets('bloquea hasta elegir candidato; elegir -> PATCH client_id y se habilita confirmar',
        (tester) => backend.run(() async {
              backend.json('PATCH', '/actions/drf_con', contactDraftResolved());
              await pumpReview(tester, contactDraftAmbiguous());

              expect(find.text('«Rivera»'), findsOneWidget);
              expect(find.text('Ambiguo: elige uno'), findsOneWidget);
              expect(find.textContaining('Hay varios clientes que encajan con «Rivera»'), findsWidgets);
              expect(confirmEnabled(tester), isFalse);

              await tapText(tester, 'Rivera Hermanos S.A.');
              expect(lastJson(backend, 'PATCH', '/actions/drf_con'), {"revision": 1, "edits": {"client_id": 2}});
              expect(find.text('Elegido por ti'), findsOneWidget);
              expect(confirmEnabled(tester), isTrue);
            }));

    testWidgets('buscar cliente en el CRM (corrección manual) -> PATCH client_id', (tester) => backend.run(() async {
          backend.json('GET', '/clients', {
            "clients": [
              {"id": 1, "name": "Construcciones Rivera S.L."},
              {"id": 2, "name": "Rivera Hermanos S.A."}
            ]
          });
          backend.json('PATCH', '/actions/drf_con', contactDraftResolved());
          await pumpReview(tester, contactDraftAmbiguous());

          await tester.tap(find.byTooltip('Buscar cliente en el CRM'));
          await tester.pumpAndSettle();
          await tester.enterText(find.widgetWithText(TextField, 'Buscar...'), 'herm');
          await tester.pumpAndSettle();
          await tapText(tester, 'Rivera Hermanos S.A.', last: true);
          expect(lastJson(backend, 'PATCH', '/actions/drf_con')["edits"], {"client_id": 2});
        }));
  });

  group('venta (ejemplo 4)', () {
    testWidgets('líneas con cantidad, producto, importe en EUR (céntimos) y total; PVP solo orientativo',
        (tester) => backend.run(() async {
              await pumpReview(tester, saleDraft());
              expect(find.text('Nueva venta · revisión'), findsOneWidget);
              expect(find.text('Portátil Luna 13'), findsOneWidget);
              expect(find.text('Dijiste «portátiles Luna 13»'), findsOneWidget);
              expect(find.text('Cantidad: 2'), findsOneWidget);
              expect(find.text('Importe: 1.500,00 €'), findsOneWidget);
              expect(find.text('PVP de catálogo: 1.798,00 € (solo orientativo)'), findsOneWidget);
              expect(find.byKey(const Key('voice-sale-total')), findsOneWidget);
              expect(tester.widget<Text>(find.byKey(const Key('voice-sale-total'))).data, '1.500,00 €');
            }));

    testWidgets('producto inexistente: bloquea; buscar en catálogo -> PATCH lines completo sin flotantes',
        (tester) => backend.run(() async {
              backend.json('GET', '/products', {
                "products": [
                  {"id": 4, "name": "Portátil Luna 13", "price": 899.0}
                ]
              });
              backend.json('PATCH', '/actions/drf_sal', saleDraft(revision: 2));
              await pumpReview(
                  tester,
                  saleDraft(product: {
                    "id": null,
                    "label": null,
                    "said": "Lunar 15",
                    "match": null,
                    "problem": "not_found",
                    "candidates": []
                  }, issues: [
                    issueJson('not_found', 'lines[0].product', 'No encuentro el producto «Lunar 15» en el CRM.')
                  ]));

              expect(find.text('No encontrado'), findsOneWidget);
              expect(confirmEnabled(tester), isFalse);
              await tester.tap(find.byTooltip('Buscar producto en el CRM'));
              await tester.pumpAndSettle();
              await tapText(tester, 'Portátil Luna 13');

              expect(lastJson(backend, 'PATCH', '/actions/drf_sal'), {
                "revision": 1,
                "edits": {
                  "lines": [
                    {"product_id": 4, "quantity": 2, "amount": "1500"}
                  ]
                }
              });
              expect(confirmEnabled(tester), isTrue);
            }));

    testWidgets('añadir línea: valida el importe y envía todas las líneas en un PATCH', (tester) => backend.run(() async {
          backend.json('PATCH', '/actions/drf_sal', saleDraft(revision: 2));
          await pumpReview(tester, saleDraft());

          await tapText(tester, 'Añadir línea');
          await tester.enterText(find.widgetWithText(TextFormField, 'Concepto *'), 'Instalación');
          await tester.enterText(find.widgetWithText(TextFormField, 'Importe total de la línea *'), '4,500');
          await tapText(tester, 'Aplicar');
          expect(find.text('Importe ambiguo: escribe 4.500 o 4500,00'), findsOneWidget);
          expect(backend.calls('PATCH', '/actions/drf_sal'), isEmpty);

          await tester.enterText(find.widgetWithText(TextFormField, 'Importe total de la línea *'), '120,50');
          await tapText(tester, 'Aplicar');
          expect(lastJson(backend, 'PATCH', '/actions/drf_sal')["edits"], {
            "lines": [
              {"product_id": 4, "quantity": 2, "amount": "1500"},
              {"concept": "Instalación", "amount": "120,50"},
            ]
          });
        }));
  });

  group('confirmación: errores y recuperación', () {
    testWidgets('sin red al confirmar: aviso y reintento idempotente con la misma revisión',
        (tester) => backend.run(() async {
              var calls = 0;
              backend.on('POST', '/actions/drf_cli/confirm', (_) {
                calls++;
                if (calls == 1) throw http.ClientException('sin red');
                return jsonResponse({
                  "result": {"entity": "client", "ids": [30], "data": {"id": 30, "name": "Construcciones Mediterráneo"}},
                  "draft": executed(clientDraft(), {"entity": "client", "ids": [30]}),
                });
              });
              await pumpReview(tester, clientDraft());

              await tapConfirm(tester);
              expect(find.textContaining('si ya se había guardado, no se duplicará'), findsOneWidget);
              await tapConfirm(tester);

              expect(backend.calls('POST', '/actions/drf_cli/confirm').map((r) => jsonDecode(r.body)),
                  [{"revision": 1}, {"revision": 1}]);
              expect(find.text('Cliente creado'), findsOneWidget);
            }));

    testWidgets('422 al confirmar: muestra los issues nuevos del servidor y deshabilita confirmar',
        (tester) => backend.run(() async {
              final blocked = {
                ...clientDraft(revision: 2),
                "issues": [issueJson('duplicate', 'client', 'Ya existe el cliente «Construcciones Mediterráneo».')],
                "confirmable": false,
              };
              backend.json('POST', '/actions/drf_cli/confirm', {
                "detail": "No se puede confirmar: Ya existe el cliente «Construcciones Mediterráneo».",
                "issues": blocked["issues"],
                "draft": blocked,
              }, status: 422);
              await pumpReview(tester, clientDraft());

              await tapConfirm(tester);
              expect(find.text('No se puede confirmar: Ya existe el cliente «Construcciones Mediterráneo».'), findsOneWidget);
              expect(find.textContaining('Para poder confirmar'), findsOneWidget);
              expect(confirmEnabled(tester), isFalse);
            }));

    testWidgets('410 caducado: estado cerrado con explicación', (tester) => backend.run(() async {
          backend.json('POST', '/actions/drf_cli/confirm',
              {"detail": "El borrador ha caducado: vuelve a dictar o escribir la acción.", "code": "draft_expired"},
              status: 410);
          await pumpReview(tester, clientDraft());
          await tapConfirm(tester);
          expect(find.text('El borrador ha caducado: vuelve a dictar o escribir la acción.'), findsOneWidget);
          expect(confirmButton(), findsNothing);
          await tapText(tester, 'Cerrar');
          expect(host.closed, isTrue);
          expect(host.outcome, isNull);
        }));
  });

  group('transcripción y cancelación', () {
    testWidgets('corregir texto y reinterpretar: nuevo borrador y se cancela el anterior; si falla se conserva el texto',
        (tester) => backend.run(() async {
              var interprets = 0;
              backend.on('POST', '/actions/interpret', (_) {
                interprets++;
                return interprets == 1
                    ? jsonResponse({"detail": "El asistente no está disponible ahora mismo.", "code": "ai_unavailable"},
                        status: 503)
                    : jsonResponse(clientDraft(), status: 201);
              });
              backend.json('POST', '/actions/drf_act/cancel', {...activityDraft(), "status": "cancelled"});
              await pumpReview(tester, activityDraft());

              await tapText(tester, 'Corregir texto');
              const corrected = 'Crea un cliente llamado Construcciones Mediterráneo en Alicante.';
              await tester.enterText(find.byKey(const Key('voice-transcript-field')), corrected);
              await tapText(tester, 'Reinterpretar');

              expect(find.text('El asistente no está disponible ahora mismo.'), findsOneWidget);
              expect(find.text(corrected), findsOneWidget); // el texto corregido sigue ahí
              expect(find.text('Nueva actividad · revisión'), findsOneWidget);

              await tapText(tester, 'Reinterpretar');
              expect(lastJson(backend, 'POST', '/actions/interpret'), {"text": corrected});
              expect(find.text('Nuevo cliente · revisión'), findsOneWidget);
              expect(backend.calls('POST', '/actions/drf_act/cancel'), hasLength(1));
            }));

    testWidgets('descartar sin cambios: cancela en el servidor y cierra sin guardar', (tester) => backend.run(() async {
          backend.json('POST', '/actions/drf_cli/cancel', {...clientDraft(), "status": "cancelled"});
          await pumpReview(tester, clientDraft());
          await tapText(tester, 'Descartar');
          expect(backend.calls('POST', '/actions/drf_cli/cancel'), hasLength(1));
          expect(host.closed, isTrue);
          expect(host.outcome, isNull);
        }));

    testWidgets('descartar con cambios pide confirmación; si ya estaba ejecutado se muestra el resultado',
        (tester) => backend.run(() async {
              backend.json('PATCH', '/actions/drf_cli', clientDraft(revision: 2, province: 'Alicante'));
              backend.json('POST', '/actions/drf_cli/cancel', {
                "detail": "Este borrador ya se confirmó: no se puede cancelar.",
                "code": "draft_executed",
                "draft": executed(clientDraft(revision: 2), {"entity": "client", "ids": [30], "data": {"id": 30}}),
              }, status: 409);
              await pumpReview(tester, clientDraft());
              await tester.tap(find.byTooltip('Cambiar provincia'));
              await tester.pumpAndSettle();
              await tester.enterText(find.byType(TextField).last, 'Alicante');
              await tapText(tester, 'Aplicar');

              await tapText(tester, 'Descartar');
              expect(find.text('Descartar la acción'), findsOneWidget);
              await tapText(tester, 'Cancelar');
              expect(backend.calls('POST', '/actions/drf_cli/cancel'), isEmpty);

              await tapText(tester, 'Descartar');
              await tapText(tester, 'Descartar', last: true);
              expect(backend.calls('POST', '/actions/drf_cli/cancel'), hasLength(1));
              expect(find.text('Cliente creado'), findsOneWidget);
            }));
  });

  final phoneDrafts = {
    'actividad': activityDraft,
    'cliente': clientDraft,
    'contacto ambiguo': contactDraftAmbiguous,
    'venta': saleDraft,
  };
  for (final entry in phoneDrafts.entries) {
    testWidgets('móvil (360 px): ${entry.key} a pantalla completa sin desbordes', (tester) => backend.run(() async {
          tester.view.physicalSize = const Size(360, 740);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final auth = await loggedInAuth(backend);
          await tester.pumpWidget(appFor(auth, host.build(entry.value())));
          await tapText(tester, 'abrir');
          expect(find.byType(AppBar), findsOneWidget); // pantalla completa
          expect(find.byKey(const Key('voice-confirm')), findsOneWidget);
        }));
  }
}
