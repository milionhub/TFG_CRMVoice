// Estabilización de Voice V2 tras la batería manual de voz.
// CREATE_CLIENT: la revisión muestra y deja editar SIEMPRE razón social,
// alias, población, provincia, teléfono, email y CIF; el aviso de un
// teléfono con cifras de más se ve sin bloquear «Confirmar y guardar».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/crm_fixtures.dart';
import 'support/test_support.dart';
import 'support/voice_fixtures.dart';

Map<String, dynamic> novaDraft({int revision = 1, String phone = '9654321100', String city = 'Elche'}) => draftJson(
      id: 'drf_nova',
      type: 'create_client',
      revision: revision,
      sourceText: 'CREA un nuevo cliente llamado NOVA digital en elche alicante. Su teléfono es 9654321100 y su '
          'correo es contacto a roba NOVA digital.es y por último su fif es B54321876',
      fields: {
        "name": "NOVA digital",
        "alias": "Nova",
        "city": city,
        "province": "Alicante",
        "group": null,
        "phone": phone,
        "email": "contacto@novadigital.es",
        "cif": "B54321876",
      },
      issues: phone.length == 9
          ? const []
          : [
              issueJson('invalid', 'phone',
                  'El teléfono tiene 10 cifras y un teléfono español tiene 9: revísalo antes de guardar.',
                  blocking: false),
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

  bool confirmEnabled(WidgetTester tester) => tester
      .widget<ButtonStyleButton>(find.descendant(
          of: find.byKey(const Key('voice-confirm')), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)))
      .enabled;

  testWidgets('CREATE_CLIENT: los siete campos se muestran y cada uno se puede editar', (tester) => backend.run(() async {
        await pumpReview(tester, novaDraft());

        const rows = {
          'Razón social': 'NOVA digital',
          'Alias': 'Nova',
          'Población': 'Elche',
          'Provincia': 'Alicante',
          'Teléfono': '9654321100',
          'Email': 'contacto@novadigital.es',
          'CIF': 'B54321876',
        };
        for (final entry in rows.entries) {
          expect(find.text(entry.key), findsOneWidget, reason: entry.key);
          expect(find.text(entry.value), findsOneWidget, reason: entry.value);
          expect(find.byTooltip('Cambiar ${entry.key.toLowerCase()}'), findsOneWidget, reason: entry.key);
        }
        // Transcripción original visible (trazabilidad)
        expect(find.textContaining('contacto a roba NOVA digital.es'), findsOneWidget);
      }));

  testWidgets('teléfono con una cifra de más: aviso visible, no bloquea; corregirlo -> PATCH phone',
      (tester) => backend.run(() async {
            backend.json('PATCH', '/actions/drf_nova', novaDraft(revision: 2, phone: '965432100'));
            await pumpReview(tester, novaDraft());

            expect(find.textContaining('El teléfono tiene 10 cifras'), findsWidgets);
            expect(confirmEnabled(tester), isTrue);

            await tester.ensureVisible(find.byTooltip('Cambiar teléfono'));
            await tester.tap(find.byTooltip('Cambiar teléfono'));
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField).last, '965432100');
            await tapText(tester, 'Aplicar');
            expect(lastJson(backend, 'PATCH', '/actions/drf_nova'), {"revision": 1, "edits": {"phone": "965432100"}});
            expect(find.text('965432100'), findsOneWidget);
            expect(find.textContaining('El teléfono tiene 10 cifras'), findsNothing);
          }));

  testWidgets('editar la población envía solo ese campo', (tester) => backend.run(() async {
        backend.json('PATCH', '/actions/drf_nova', novaDraft(revision: 2, city: 'Santa Pola'));
        await pumpReview(tester, novaDraft());

        await tester.ensureVisible(find.byTooltip('Cambiar población'));
        await tester.tap(find.byTooltip('Cambiar población'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'Santa Pola');
        await tapText(tester, 'Aplicar');
        expect(lastJson(backend, 'PATCH', '/actions/drf_nova'), {"revision": 1, "edits": {"city": "Santa Pola"}});
        expect(find.text('Santa Pola'), findsOneWidget);
      }));
}
