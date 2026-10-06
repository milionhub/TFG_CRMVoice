// Borradores (DraftView de H.2) para los tests de Voice V2 (H.4). Formas
// reales de schemas/actions.py: el servidor resuelve, la app solo muestra.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/action_draft.dart';
import 'package:frontend/widgets/voice/draft_review.dart';

import 'crm_fixtures.dart';

Map<String, dynamic> draftJson({
  String id = 'drf_1',
  required String type,
  required String sourceText,
  required Map<String, dynamic> fields,
  List<Map<String, dynamic>> issues = const [],
  int revision = 1,
  String status = 'open',
  bool? confirmable,
  Map<String, dynamic>? result,
}) =>
    {
      "id": id,
      "action_type": type,
      "status": status,
      "revision": revision,
      "source": "voice",
      "source_text": sourceText,
      "fields": fields,
      "issues": issues,
      "confirmable": confirmable ?? (status == 'open' && !issues.any((i) => i["blocking"] == true)),
      "expired": false,
      "expires_at": "2026-10-06T12:00:00",
      "result": result,
      "created_at": "2026-10-06T11:30:00",
      "updated_at": "2026-10-06T11:30:00",
    };

Map<String, dynamic> issueJson(String code, String field, String message,
        {bool blocking = true, List<Map<String, dynamic>> candidates = const []}) =>
    {"code": code, "field": field, "message": message, "blocking": blocking, "candidates": candidates};

const riveraExact = {"id": 1, "label": "Construcciones Rivera S.L.", "said": "Rivera", "match": "partial", "problem": null, "candidates": []};

final tomorrow = DateTime.now().add(const Duration(days: 1));

/// Ejemplo 1: «Mañana a las diez tengo que llamar a Ana de Rivera para hablar del portátil Luna 13.»
Map<String, dynamic> activityDraft({String id = 'drf_act', int revision = 1, List<Map<String, dynamic>>? products,
        List<Map<String, dynamic>> issues = const []}) =>
    draftJson(
      id: id,
      type: 'create_activity',
      revision: revision,
      sourceText: 'Mañana a las diez tengo que llamar a Ana de Rivera para hablar del portátil Luna 13.',
      fields: {
        "client": riveraExact,
        "contact": {"id": 7, "label": "Ana Martínez", "said": "Ana", "match": "partial", "problem": null, "candidates": []},
        "activity_type": {"id": 5, "label": "Realizar llamada de seguimiento", "said": "Realizar llamada de seguimiento", "match": "exact", "problem": null, "candidates": []},
        "date": isoDay(tomorrow),
        "time": "10:00",
        "time_defaulted": false,
        "status": "pending",
        "products": products ??
            [
              {"id": 4, "label": "Portátil Luna 13", "said": "portátil Luna 13", "match": "exact", "problem": null, "candidates": []}
            ],
        "comment": "Hablar del portátil Luna 13",
      },
      issues: [
        issueJson('fuzzy_match', 'client', 'Has dicho «Rivera»: Construcciones Rivera S.L.', blocking: false),
        ...issues,
      ],
    );

/// Ejemplo 2: «Crea un cliente llamado Construcciones Mediterráneo en Alicante.»
Map<String, dynamic> clientDraft({int revision = 1, String? province}) => draftJson(
      id: 'drf_cli',
      type: 'create_client',
      revision: revision,
      sourceText: 'Crea un cliente llamado Construcciones Mediterráneo en Alicante.',
      fields: {"name": "Construcciones Mediterráneo", "alias": null, "city": "Alicante", "province": province, "group": null},
    );

/// Ejemplo 3 con «Rivera» ambiguo: el servidor ofrece candidatos y bloquea.
Map<String, dynamic> contactDraftAmbiguous() => draftJson(
      id: 'drf_con',
      type: 'create_contact',
      sourceText: 'Añade a Pedro García como responsable de obra de Rivera.',
      fields: {
        "client": {
          "id": null,
          "label": null,
          "said": "Rivera",
          "match": null,
          "problem": "ambiguous",
          "candidates": [
            {"id": 1, "label": "Construcciones Rivera S.L."},
            {"id": 2, "label": "Rivera Hermanos S.A."}
          ]
        },
        "name": "Pedro García",
        "role": "Responsable de obra",
        "email": null,
        "phone": null,
      },
      issues: [
        issueJson('ambiguous', 'client', 'Hay varios clientes que encajan con «Rivera»: elige uno.', candidates: [
          {"id": 1, "label": "Construcciones Rivera S.L."},
          {"id": 2, "label": "Rivera Hermanos S.A."}
        ])
      ],
    );

Map<String, dynamic> contactDraftResolved() => draftJson(
      id: 'drf_con',
      type: 'create_contact',
      revision: 2,
      sourceText: 'Añade a Pedro García como responsable de obra de Rivera.',
      fields: {
        "client": {"id": 2, "label": "Rivera Hermanos S.A.", "said": null, "match": "user_selected", "problem": null, "candidates": []},
        "name": "Pedro García",
        "role": "Responsable de obra",
        "email": null,
        "phone": null,
      },
    );

/// Ejemplo 4: «He vendido dos portátiles Luna 13 a Rivera por mil quinientos euros.»
Map<String, dynamic> saleDraft({Map<String, dynamic>? product, int revision = 1, List<Map<String, dynamic>> issues = const []}) =>
    draftJson(
      id: 'drf_sal',
      type: 'create_sale',
      revision: revision,
      sourceText: 'He vendido dos portátiles Luna 13 a Rivera por mil quinientos euros.',
      fields: {
        "client": riveraExact,
        "contact": null,
        "sale_date": isoDay(DateTime.now()),
        "lines": [
          {
            "product": product ??
                {"id": 4, "label": "Portátil Luna 13", "said": "portátiles Luna 13", "match": "partial", "problem": null, "candidates": []},
            "concept": null,
            "quantity": 2,
            "amount_cents": 150000,
            "amount_said": "1500.00",
            "amount_error": null,
            "reference_total_cents": 179800,
          }
        ],
        "notes": null,
      },
      issues: issues,
    );

/// Pantalla base que abre la revisión y guarda lo que devuelve.
class ReviewHost {
  VoiceReviewOutcome? outcome;
  bool closed = false;

  Widget build(Map<String, dynamic> draft) => hostWith((context) async {
        outcome = await openDraftReview(context, draft: ActionDraft.tryParse(draft)!);
        closed = true;
      });
}

Future<void> pumpFrames(WidgetTester tester) => tester.pumpAndSettle();
