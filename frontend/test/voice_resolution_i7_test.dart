// I.7 · Voice V2: la revisión muestra lo que el servidor ya resuelve.
// - CREATE_CLIENT: teléfono, email y CIF se ven y se editan (PATCH tipado).
// - Elegir un contacto ambiguo: el servidor deduce su cliente y la revisión
//   muestra «Elegido por ti» / «Deducido del contacto» y habilita confirmar.
// Sin cambios de diseño: mismas filas y badges de I.6.4.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';
import 'support/voice_fixtures.dart';

Map<String, dynamic> nasaDraft({int revision = 1, String phone = '965123456'}) => draftJson(
      id: 'drf_nasa',
      type: 'create_client',
      revision: revision,
      sourceText: 'Crea un nuevo cliente llamado NASA Academia, en Alicante, con teléfono 965 123 456, '
          'email contacto arroba nasaacademia punto es y CIF B 54 321 678.',
      fields: {
        "name": "NASA Academia",
        "alias": null,
        "city": "Alicante",
        "province": "Alicante",
        "group": null,
        "phone": phone,
        "email": "contacto@nasaacademia.es",
        "cif": "B54321678",
      },
    );

const _call = {"id": 5, "label": "Realizar llamada de seguimiento", "said": "Realizar llamada de seguimiento", "match": "exact", "problem": null, "candidates": []};

Map<String, dynamic> carlosDraft({required bool chosen}) => draftJson(
      id: 'drf_carlos',
      type: 'create_activity',
      revision: chosen ? 2 : 1,
      sourceText: 'Programa una llamada pasado mañana a las 11 con Carlos',
      fields: {
        "client": chosen
            ? {"id": 3, "label": "Instituto San Lucas", "said": null, "match": "inherited", "problem": null, "candidates": []}
            : null,
        "contact": chosen
            ? {"id": 5, "label": "Carlos Ruiz", "said": null, "match": "user_selected", "problem": null, "candidates": []}
            : {
                "id": null,
                "label": null,
                "said": "Carlos",
                "match": null,
                "problem": "ambiguous",
                "candidates": [
                  {"id": 2, "label": "Carlos Perez (Tecnologia Rivera SL)"},
                  {"id": 5, "label": "Carlos Ruiz (Instituto San Lucas)"},
                ],
              },
        "activity_type": _call,
        "date": isoDay(DateTime.now().add(const Duration(days: 2))),
        "time": "11:00",
        "time_defaulted": false,
        "status": "pending",
        "products": [],
        "comment": "Llamada",
      },
      issues: chosen
          ? [issueJson('fuzzy_match', 'client', 'Cliente deducido del contacto: Instituto San Lucas.', blocking: false)]
          : [
              issueJson('missing', 'client', 'Falta el cliente.'),
              issueJson('ambiguous', 'contact', 'Hay varios contactos que encajan con «Carlos»: elige uno.', candidates: [
                {"id": 2, "label": "Carlos Perez (Tecnologia Rivera SL)"},
                {"id": 5, "label": "Carlos Ruiz (Instituto San Lucas)"},
              ]),
            ],
    );

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
  bool confirmEnabled(WidgetTester tester) => tester
      .widget<ButtonStyleButton>(find.descendant(of: confirmButton(), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)))
      .enabled;

  testWidgets('CREATE_CLIENT: teléfono, email y CIF se muestran en «Esto se guardará» y se editan',
      (tester) => backend.run(() async {
            backend.json('PATCH', '/actions/drf_nasa', nasaDraft(revision: 2, phone: '966000111'));
            await pumpReview(tester, nasaDraft());

            for (final label in ['Teléfono', 'Email', 'CIF']) {
              expect(find.text(label), findsOneWidget);
            }
            expect(find.text('965123456'), findsOneWidget);
            expect(find.text('contacto@nasaacademia.es'), findsOneWidget);
            expect(find.text('B54321678'), findsOneWidget);
            expect(confirmEnabled(tester), isTrue);

            await tester.ensureVisible(find.byTooltip('Cambiar teléfono'));
            await tester.tap(find.byTooltip('Cambiar teléfono'));
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField).last, '966-000-111');
            await tapText(tester, 'Aplicar');
            expect(lastJson(backend, 'PATCH', '/actions/drf_nasa'), {"revision": 1, "edits": {"phone": "966-000-111"}});
            expect(find.text('966000111'), findsOneWidget);   // normalizado por el servidor
          }));

  testWidgets('elegir uno de los dos Carlos -> PATCH contact_id; el cliente llega deducido y se puede confirmar',
      (tester) => backend.run(() async {
            backend.json('PATCH', '/actions/drf_carlos', carlosDraft(chosen: true));
            await pumpReview(tester, carlosDraft(chosen: false));

            expect(find.text('Varias coincidencias'), findsOneWidget);
            expect(confirmEnabled(tester), isFalse);

            await tapText(tester, 'Carlos Ruiz (Instituto San Lucas)');
            expect(lastJson(backend, 'PATCH', '/actions/drf_carlos'), {"revision": 1, "edits": {"contact_id": 5}});
            expect(find.text('Elegido por ti'), findsOneWidget);
            expect(find.text('Deducido del contacto'), findsOneWidget);
            expect(find.text('Instituto San Lucas'), findsWidgets);
            expect(confirmEnabled(tester), isTrue);
          }));
}
