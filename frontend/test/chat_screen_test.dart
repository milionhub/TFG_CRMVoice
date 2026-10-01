// Chat V2 (G.5): estado vacío y ejemplos, envío por ApiService, contexto SOLO
// desde la metadata estructurada, Markdown legible, nueva conversación,
// errores y reintentos, teclado, scroll y conservación del estado al cambiar
// de escritorio a móvil. Todo contra FakeBackend: sin red ni OpenAI.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/chat_screen.dart';
import 'package:frontend/widgets/chat/chat_empty_state.dart';
import 'package:frontend/widgets/chat/chat_message_bubble.dart';
import 'package:frontend/widgets/chat/chat_theme.dart';
import 'package:http/http.dart' as http;

import 'support/test_support.dart';

const _noMetadata = Object();

http.Response chatReply(String content,
    {int? conversationId = 42, Object? metadata = _noMetadata, String type = 'answer'}) {
  return http.Response(
    jsonEncode({
      "type": type,
      "content": content,
      "metadata": identical(metadata, _noMetadata) ? null : metadata,
      "conversation_id": conversationId,
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, Object?> ctx({String? client, String? contact}) => {
      "active_client": client == null ? null : {"id": 1, "name": client},
      "active_contact": contact == null ? null : {"id": 3, "name": contact, "client_id": 1},
    };

void main() {
  late FakeBackend backend;
  late AuthProvider auth;

  setUp(() {
    cleanPreferences();
    backend = FakeBackend();
  });

  tearDown(() => backend.expectNoUnexpectedRequests());

  Future<void> pumpChat(WidgetTester tester, {bool desktop = true, AuthProvider? session}) async {
    if (desktop) {
      useDesktopSurface(tester);
    } else {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    auth = session ?? await loggedInAuth(backend);
    await tester.pumpWidget(appFor(auth, const ChatScreen()));
    await tester.pumpAndSettle();
  }

  // El Tooltip "Enviar" está dentro del IconButton
  Finder sendButton() => find.ancestor(of: find.byTooltip('Enviar'), matching: find.byType(IconButton));

  /// Escribe y deja que el botón de enviar se actualice (siguiente frame).
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await type(tester, text);
    await tester.tap(sendButton());
    await tester.pumpAndSettle();
  }

  bool shows(String text) => find.textContaining(text, findRichText: true).evaluate().isNotEmpty;

  List<Map<String, dynamic>> chatBodies() => backend
      .calls('POST', '/chat')
      .map((r) => jsonDecode(r.body) as Map<String, dynamic>)
      .toList();

  bool sendEnabled(WidgetTester tester) => tester.widget<IconButton>(sendButton()).onPressed != null;

  ChatViewState chatState(WidgetTester tester) => tester.state<ChatViewState>(find.byType(ChatView));

  // ===================================================================
  // Estado vacío y ejemplos
  // ===================================================================

  testWidgets('estado vacío con título, ayuda y los seis ejemplos', (tester) => backend.run(() async {
        await pumpChat(tester);

        expect(find.text(ChatEmptyState.title), findsOneWidget);
        expect(shows('sin modificarlos'), isTrue);
        for (final prompt in ChatEmptyState.prompts) {
          expect(find.text(prompt.text), findsOneWidget);
        }
        expect(find.text('CRMVoice IA'), findsOneWidget);
        expect(find.text('Consulta tu CRM en lenguaje natural'), findsOneWidget);
        expect(find.byType(UserMessage), findsNothing);
      }));

  for (final (width, columns) in [(1400.0, 3), (1000.0, 2), (400.0, 1)]) {
    testWidgets('ejemplos en $columns columna(s) a $width px', (tester) => backend.run(() async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          auth = await loggedInAuth(backend);
          await tester.pumpWidget(appFor(auth, const ChatScreen()));
          await tester.pumpAndSettle();

          final lefts = {
            for (final prompt in ChatEmptyState.prompts)
              tester.getTopLeft(find.text(prompt.text)).dx.round(),
          };
          expect(lefts, hasLength(columns));
        }));
  }

  testWidgets('un ejemplo envía exactamente su texto por el camino normal', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => chatReply('Rivera va bien.'));
        await pumpChat(tester);

        await tester.tap(find.text('¿Cómo va Rivera?'));
        await tester.pumpAndSettle();

        expect(chatBodies(), [
          {"message": "¿Cómo va Rivera?"}
        ]);
        expect(find.widgetWithText(UserMessage, '¿Cómo va Rivera?'), findsOneWidget);
        expect(shows('Rivera va bien.'), isTrue);
        expect(find.text(ChatEmptyState.title), findsNothing);
      }));

  testWidgets('los ejemplos exponen la acción tap a los lectores de pantalla', (tester) => backend.run(() async {
        final semantics = tester.ensureSemantics();
        backend.on('POST', '/chat', (_) => chatReply('ok'));
        await pumpChat(tester);

        final starter = find.bySemanticsLabel('Preguntar: ¿Cómo va Rivera?');
        expect(tester.getSemantics(starter), isSemantics(isButton: true, hasTapAction: true, isEnabled: true));

        // La acción semántica envía como un toque normal
        tester.semantics.tap(find.semantics.byLabel('Preguntar: ¿Cómo va Rivera?'));
        await tester.pumpAndSettle();
        expect(chatBodies(), [
          {"message": "¿Cómo va Rivera?"}
        ]);
        semantics.dispose();
      }));

  testWidgets('un ejemplo no borra el borrador del composer', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => chatReply('Mañana nada.'));
        await pumpChat(tester);

        await type(tester, 'borrador a medias');
        await tester.tap(find.text('¿Qué tengo mañana?'));
        await tester.pumpAndSettle();

        expect(chatBodies(), [
          {"message": "¿Qué tengo mañana?"}
        ]);
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'borrador a medias');

        // Un envío desde el composer sí lo vacía
        await tester.tap(sendButton());
        await tester.pumpAndSettle();
        expect(chatBodies().last, {"message": "borrador a medias", "conversation_id": 42});
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      }));

  // ===================================================================
  // Envío, carga y respuesta
  // ===================================================================

  testWidgets('el mensaje aparece al momento, el composer se vacía y se muestra la carga',
      (tester) => backend.run(() async {
            final pending = Completer<http.Response>();
            backend.on('POST', '/chat', (_) => pending.future);
            await pumpChat(tester);

            await type(tester, '¿Qué tengo mañana?');
            await tester.tap(sendButton());
            await tester.pump();

            expect(find.widgetWithText(UserMessage, '¿Qué tengo mañana?'), findsOneWidget);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
            expect(find.byType(PendingMessage), findsOneWidget);
            expect(find.text(PendingMessage.text), findsOneWidget);
            expect(sendEnabled(tester), isFalse);

            pending.complete(chatReply('Mañana tienes dos reuniones.'));
            await tester.pumpAndSettle();

            expect(find.byType(PendingMessage), findsNothing);
            expect(find.byType(AssistantMessage), findsOneWidget);
            expect(shows('Mañana tienes dos reuniones.'), isTrue);
          }));

  testWidgets('Markdown: títulos, listas y negrita con la hoja de estilos del chat', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => chatReply('## Resumen\n\n- **Rivera**: 3 actividades\n- Sierra Norte\n\n1. Primero'));
        await pumpChat(tester);

        await send(tester, 'resumen');

        final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
        expect(shows('Resumen'), isTrue);
        expect(shows('Rivera'), isTrue);
        expect(shows('Sierra Norte'), isTrue);
        // Nada hereda del ThemeData.dark() global: colores explícitos y oscuros sobre blanco
        final style = markdown.styleSheet!;
        expect(style.p!.color, ChatColors.textPrimary);
        expect(style.h1!.color, ChatColors.textPrimary);
        expect(style.h2!.color, ChatColors.textPrimary);
        expect(style.h3!.color, ChatColors.textPrimary);
        expect(style.listBullet!.color, ChatColors.textSecondary);
        expect(style.blockquote!.color, ChatColors.textSecondary);
        expect(style.a!.color, ChatColors.accent);
        expect(style.strong!.fontWeight, FontWeight.w600);
        expect(find.byType(SelectionArea), findsOneWidget);
      }));

  testWidgets('las imágenes del Markdown no se cargan: solo su texto alternativo', (tester) => backend.run(() async {
        backend.on(
            'POST',
            '/chat',
            (_) => chatReply('Resumen\n\n![logo](https://example.invalid/x.png?d=Rivera)\n\n'
                '![](C:/Users/ana/secreto.png) ![local](file:///etc/passwd) ![](/tmp/x.png)'));
        await pumpChat(tester);

        await send(tester, 'resumen');

        expect(find.byType(Image), findsNothing); // ni Image.network ni Image.file
        expect(shows('Resumen'), isTrue);
        expect(shows('logo'), isTrue);
        expect(shows('local'), isTrue);
        expect(tester.takeException(), isNull);
      }));

  // ===================================================================
  // Contexto: SOLO metadata estructurada
  // ===================================================================

  testWidgets('cliente y contacto activos salen de la metadata', (tester) => backend.run(() async {
        final replies = [
          chatReply('Rivera va bien.', metadata: ctx(client: 'Tecnologia Rivera SL')),
          chatReply('Carlos Perez.', metadata: ctx(client: 'Tecnologia Rivera SL', contact: 'Carlos Perez')),
        ];
        backend.on('POST', '/chat', (_) => replies.removeAt(0));
        await pumpChat(tester);

        await send(tester, '¿Cómo va Rivera?');
        expect(find.text('Contexto'), findsOneWidget);
        expect(find.text('Tecnologia Rivera SL'), findsOneWidget);

        await send(tester, '¿Quién es Carlos?');
        expect(find.text('Tecnologia Rivera SL'), findsOneWidget);
        expect(find.text('Carlos Perez'), findsOneWidget);
      }));

  testWidgets('la metadata sustituye el contexto: otro cliente reemplaza al anterior y el contacto puede quitarse',
      (tester) => backend.run(() async {
            final replies = [
              chatReply('A.', metadata: ctx(client: 'Tecnologia Rivera SL', contact: 'Carlos Perez')),
              chatReply('B.', metadata: {
                "active_client": {"id": 2, "name": "Diputacion Costa Verde"},
                "active_contact": {"id": 5, "name": "Laura Gil", "client_id": 2},
              }),
              chatReply('C.', metadata: {
                "active_client": {"id": 2, "name": "Diputacion Costa Verde"},
                "active_contact": null,
              }),
            ];
            backend.on('POST', '/chat', (_) => replies.removeAt(0));
            await pumpChat(tester);

            await send(tester, '¿Cómo va Rivera?');
            expect(find.text('Tecnologia Rivera SL'), findsOneWidget);
            expect(find.text('Carlos Perez'), findsOneWidget);

            await send(tester, '¿Y Costa?');
            expect(find.text('Tecnologia Rivera SL'), findsNothing);
            expect(find.text('Carlos Perez'), findsNothing);
            expect(find.text('Diputacion Costa Verde'), findsOneWidget);
            expect(find.text('Laura Gil'), findsOneWidget);

            await send(tester, 'Hablemos del cliente en general');
            expect(find.text('Diputacion Costa Verde'), findsOneWidget);
            expect(find.text('Laura Gil'), findsNothing);
          }));

  testWidgets('metadata con nulos borra el contexto; sin metadata se conserva', (tester) => backend.run(() async {
        final replies = [
          chatReply('Costa va bien.', metadata: ctx(client: 'Diputacion Costa Verde')),
          chatReply('Respuesta sin metadata.', metadata: null),
          chatReply('Hecho.', metadata: ctx()),
        ];
        backend.on('POST', '/chat', (_) => replies.removeAt(0));
        await pumpChat(tester);

        await send(tester, '¿Cómo va Costa?');
        expect(find.text('Diputacion Costa Verde'), findsOneWidget);

        await send(tester, 'otra cosa');
        expect(find.text('Diputacion Costa Verde'), findsOneWidget);   // metadata ausente: no se toca

        await send(tester, 'Olvida ese cliente');
        expect(find.text('Diputacion Costa Verde'), findsNothing);      // metadata con nulos: borrado
        expect(find.text('Contexto'), findsNothing);
      }));

  testWidgets('nunca se deduce contexto del texto del usuario ni del asistente', (tester) => backend.run(() async {
        backend.on('POST', '/chat',
            (_) => chatReply('Has hablado del Monitor Mar 24 con el cliente Diputacion Costa Verde.', metadata: null));
        await pumpChat(tester);

        await send(tester, '¿Con qué clientes he hablado del Monitor Mar 24?');

        expect(find.text('Contexto'), findsNothing);
        expect(shows('Cliente activo'), isFalse);
        expect(shows('s he hablado del Monitor'), isTrue);   // solo dentro del propio mensaje del usuario
        expect(find.widgetWithText(UserMessage, '¿Con qué clientes he hablado del Monitor Mar 24?'), findsOneWidget);
      }));

  // ===================================================================
  // Nueva conversación
  // ===================================================================

  testWidgets('Nueva conversación borra mensajes, contexto e id; la siguiente va sin id',
      (tester) => backend.run(() async {
            backend.on('POST', '/chat', (_) => chatReply('Rivera ok.', metadata: ctx(client: 'Tecnologia Rivera SL')));
            await pumpChat(tester);

            await send(tester, '¿Cómo va Rivera?');
            expect(find.text('Tecnologia Rivera SL'), findsOneWidget);

            await tester.tap(find.text('Nueva conversación'));
            await tester.pumpAndSettle();

            expect(find.text(ChatEmptyState.title), findsOneWidget);
            expect(find.byType(UserMessage), findsNothing);
            expect(find.text('Tecnologia Rivera SL'), findsNothing);

            await send(tester, '¿Qué tengo mañana?');
            expect(chatBodies().last, {"message": "¿Qué tengo mañana?"});
            expect(chatBodies().first, {"message": "¿Cómo va Rivera?"});
          }));

  testWidgets('Nueva conversación está deshabilitada sin mensajes y durante una consulta',
      (tester) => backend.run(() async {
            final pending = Completer<http.Response>();
            backend.on('POST', '/chat', (_) => pending.future);
            await pumpChat(tester);

            OutlinedButton newButton() =>
                tester.widget<OutlinedButton>(find.ancestor(of: find.text('Nueva conversación'), matching: find.byType(OutlinedButton)));
            expect(newButton().onPressed, isNull);

            await type(tester, 'hola');
            await tester.tap(sendButton());
            await tester.pump();
            expect(newButton().onPressed, isNull);

            pending.complete(chatReply('hola'));
            await tester.pumpAndSettle();
            expect(newButton().onPressed, isNotNull);
          }));

  testWidgets('una respuesta que llega tras reiniciar se ignora', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        backend.on('POST', '/chat', (_) => pending.future);
        await pumpChat(tester);

        await type(tester, 'pregunta vieja');
        await tester.tap(sendButton());
        await tester.pump();

        chatState(tester).newConversation();
        await tester.pump();
        pending.complete(chatReply('RESPUESTA VIEJA', metadata: ctx(client: 'Tecnologia Rivera SL')));
        await tester.pumpAndSettle();

        expect(shows('RESPUESTA VIEJA'), isFalse);
        expect(find.text('Tecnologia Rivera SL'), findsNothing);
        expect(find.text(ChatEmptyState.title), findsOneWidget);
      }));

  // ===================================================================
  // Errores y reintentos
  // ===================================================================

  testWidgets('404: empieza otra conversación, conserva la pregunta y reintenta sin id',
      (tester) => backend.run(() async {
            final replies = <http.Response>[
              chatReply('uno', conversationId: 42, metadata: ctx(client: 'Tecnologia Rivera SL')),
              http.Response('{"detail": "Conversación no encontrada"}', 404),
              chatReply('dos', conversationId: 43),
            ];
            backend.on('POST', '/chat', (_) => replies.removeAt(0));
            await pumpChat(tester);

            await send(tester, 'uno');
            await send(tester, 'dos');

            expect(shows('La conversación anterior ya no está disponible. He empezado una nueva.'), isTrue);
            expect(find.text('Tecnologia Rivera SL'), findsNothing);
            expect(find.widgetWithText(UserMessage, 'dos'), findsOneWidget);

            await tester.tap(find.text('Reintentar'));
            await tester.pumpAndSettle();

            expect(chatBodies(), [
              {"message": "uno"},
              {"message": "dos", "conversation_id": 42},
              {"message": "dos"},
            ]);
            expect(find.widgetWithText(UserMessage, 'dos'), findsOneWidget);   // sin duplicar
            expect(shows('ya no está disponible'), isFalse);
          }));

  testWidgets('type:error del backend: aviso, metadata aplicada y reintento con el mismo id',
      (tester) => backend.run(() async {
            final replies = <http.Response>[
              chatReply('Rivera ok.', metadata: ctx(client: 'Tecnologia Rivera SL')),
              chatReply('El asistente de IA no está disponible en este momento.', type: 'error',
                  metadata: ctx(client: 'Tecnologia Rivera SL')),
              chatReply('Ahora sí.', metadata: ctx(client: 'Tecnologia Rivera SL')),
            ];
            backend.on('POST', '/chat', (_) => replies.removeAt(0));
            await pumpChat(tester);

            await send(tester, '¿Cómo va Rivera?');
            await send(tester, '¿Y con ellos?');

            expect(find.widgetWithText(NoticeMessage, 'El asistente de IA no está disponible en este momento.'),
                findsOneWidget);
            expect(find.byType(AssistantMessage), findsOneWidget);
            expect(find.text('Tecnologia Rivera SL'), findsOneWidget);

            await tester.tap(find.text('Reintentar'));
            await tester.pumpAndSettle();

            expect(chatBodies().last, {"message": "¿Y con ellos?", "conversation_id": 42});
            expect(find.widgetWithText(UserMessage, '¿Y con ellos?'), findsOneWidget);
            expect(shows('Ahora sí.'), isTrue);
          }));

  testWidgets('error de red: aviso y reintento', (tester) => backend.run(() async {
        var fail = true;
        backend.on('POST', '/chat', (_) {
          if (fail) throw http.ClientException('sin conexión con detalles internos');
          return chatReply('Ya funciona.');
        });
        await pumpChat(tester);

        await send(tester, 'hola');
        expect(shows('No se pudo enviar la consulta.'), isTrue);
        expect(shows('detalles internos'), isFalse);

        fail = false;
        await tester.tap(find.text('Reintentar'));
        await tester.pumpAndSettle();
        expect(shows('Ya funciona.'), isTrue);
        expect(find.widgetWithText(UserMessage, 'hola'), findsOneWidget);
      }));

  testWidgets('solo el último turno fallido se puede reintentar', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => throw http.ClientException('sin conexión'));
        await pumpChat(tester);

        await send(tester, 'primera');
        await send(tester, 'segunda');
        expect(find.text('No se pudo enviar la consulta.'), findsNWidgets(2));
        expect(find.text('Reintentar'), findsOneWidget);

        backend.on('POST', '/chat', (_) => chatReply('Respuesta a la segunda.'));
        await tester.tap(find.text('Reintentar'));
        await tester.pumpAndSettle();

        expect(chatBodies().last['message'], 'segunda');
        expect(find.widgetWithText(UserMessage, 'segunda'), findsOneWidget);
        expect(find.text('Reintentar'), findsNothing);
      }));

  testWidgets('los avisos de error son región viva para el lector de pantalla', (tester) => backend.run(() async {
        final semantics = tester.ensureSemantics();
        backend.on('POST', '/chat', (_) => throw http.ClientException('sin conexión'));
        await pumpChat(tester);

        await send(tester, 'hola');

        expect(tester.getSemantics(find.byType(NoticeMessage)), isSemantics(isLiveRegion: true));
        semantics.dispose();
      }));

  testWidgets('timeout de 45 s: aviso de envío fallido', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => Completer<http.Response>().future);
        await pumpChat(tester);

        await type(tester, 'hola');
        await tester.tap(sendButton());
        await tester.pump(const Duration(seconds: 46));
        await tester.pumpAndSettle();

        expect(shows('No se pudo enviar la consulta.'), isTrue);
        expect(find.byType(PendingMessage), findsNothing);
      }));

  testWidgets('500 u otro estado: aviso genérico sin cuerpo del servidor', (tester) => backend.run(() async {
        backend.json('POST', '/chat', {"detail": "Traceback secreto"}, status: 500);
        await pumpChat(tester);

        await send(tester, 'hola');

        expect(shows('No se ha podido completar la consulta.'), isTrue);
        expect(shows('Traceback'), isFalse);
        expect(find.text('Reintentar'), findsOneWidget);
      }));

  // El logout real al pulsar "Iniciar sesión" se prueba en chat_session_test.dart
  // (GoogleSignIn.signOut solo admite un testWidgets por archivo).
  testWidgets('401: aviso de sesión caducada con "Iniciar sesión" y sin reintento', (tester) => backend.run(() async {
        backend.json('POST', '/chat', {"detail": "Token inválido"}, status: 401);
        await pumpChat(tester);

        await send(tester, 'hola');
        expect(shows('Tu sesión ha caducado. Vuelve a iniciar sesión.'), isTrue);
        expect(find.text('Reintentar'), findsNothing);
        expect(find.widgetWithText(OutlinedButton, 'Iniciar sesión'), findsOneWidget);
        expect(shows('Token inválido'), isFalse);
      }));

  testWidgets('sin token no envía "Bearer null"', (tester) => backend.run(() async {
        backend.json('POST', '/chat', {"detail": "Not authenticated"}, status: 401);
        await pumpChat(tester, session: AuthProvider());

        await send(tester, 'hola');

        expect(backend.calls('POST', '/chat').single.headers.containsKey('Authorization'), isFalse);
      }));

  // ===================================================================
  // Composer y teclado
  // ===================================================================

  testWidgets('no se envía otro mensaje mientras se espera (botón, Enter ni ejemplo)', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        backend.on('POST', '/chat', (_) => pending.future);
        await pumpChat(tester);

        await type(tester, 'uno');
        await tester.tap(sendButton());
        await tester.pump();
        await type(tester, 'dos');
        await tester.tap(sendButton());
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(backend.calls('POST', '/chat'), hasLength(1));
        pending.complete(chatReply('hecho'));
        await tester.pumpAndSettle();
        expect(backend.calls('POST', '/chat'), hasLength(1));
      }));

  testWidgets('vacío o solo espacios no se envía', (tester) => backend.run(() async {
        await pumpChat(tester);

        expect(sendEnabled(tester), isFalse);
        await type(tester, '   \n  ');
        await tester.pump();
        expect(sendEnabled(tester), isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(backend.calls('POST', '/chat'), isEmpty);
      }));

  testWidgets('máximo 2000 caracteres, como el backend', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => chatReply('ok'));
        await pumpChat(tester);

        await send(tester, 'a' * 2100);

        expect((chatBodies().single["message"] as String).length, 2000);
      }));

  testWidgets('el límite cuenta code points como el backend: 1500 emoji se envían', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => chatReply('ok'));
        await pumpChat(tester);

        await type(tester, '😀' * 1500); // 3000 unidades UTF-16, 1500 code points
        expect(sendEnabled(tester), isTrue);
        await tester.tap(sendButton());
        await tester.pumpAndSettle();

        expect((chatBodies().single["message"] as String).runes.length, 1500);
      }));

  testWidgets('por encima de 2000 code points no hay botón activo que no haga nada', (tester) => backend.run(() async {
        await pumpChat(tester);

        // "é" descompuesta (NFD): 1 grafema, 2 code points. 1100 caben en el TextField, pero son 2200
        await type(tester, 'e\u0301' * 1100);
        expect(sendEnabled(tester), isFalse);
        expect(find.textContaining('2200 / 2000'), findsOneWidget);

        await tester.tap(sendButton());
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(backend.calls('POST', '/chat'), isEmpty);
      }));

  testWidgets('Enter envía y Shift+Enter no', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => chatReply('ok'));
        await pumpChat(tester);

        await tester.tap(find.byType(TextField));
        await type(tester, 'línea uno');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(backend.calls('POST', '/chat'), isEmpty);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(chatBodies(), [
          {"message": "línea uno"}
        ]);
      }));

  // ===================================================================
  // Scroll y tamaño de ventana
  // ===================================================================

  testWidgets('una respuesta larga se muestra desde su principio', (tester) => backend.run(() async {
        final long = ['INICIO de la respuesta', for (var i = 0; i < 80; i++) '- línea $i', 'FINAL de la respuesta'].join('\n');
        backend.on('POST', '/chat', (_) => chatReply(long));
        await pumpChat(tester);

        await send(tester, 'dame todo');

        final viewport = tester.getRect(find.byType(ListView));
        final start = tester.getRect(find.textContaining('INICIO de la respuesta', findRichText: true));
        expect(start.top, greaterThanOrEqualTo(viewport.top - 1));
        expect(start.top, lessThan(viewport.bottom));
        expect(find.textContaining('FINAL de la respuesta', findRichText: true).hitTestable(), findsNothing);
      }));

  testWidgets('tras varios turnos, una respuesta larga se muestra desde su principio', (tester) => backend.run(() async {
        var turn = 0;
        backend.on('POST', '/chat', (_) {
          turn++;
          if (turn < 6) return chatReply([for (var i = 0; i < 25; i++) '- previa $turn.$i'].join('\n'));
          return chatReply(['INICIO de la larga', for (var i = 0; i < 80; i++) '- línea $i', 'FINAL de la larga'].join('\n'));
        });
        await pumpChat(tester);

        for (var i = 0; i < 6; i++) {
          await send(tester, 'pregunta $i');
        }

        // El inicio queda arriba del todo (no abajo, donde estaba la carga) y el final, fuera
        final viewport = tester.getRect(find.byType(ListView));
        final start = tester.getRect(find.textContaining('INICIO de la larga', findRichText: true));
        expect(start.top, greaterThanOrEqualTo(viewport.top - 1));
        expect(start.top - viewport.top, lessThan(100));
        expect(find.textContaining('FINAL de la larga', findRichText: true).hitTestable(), findsNothing);
      }));

  testWidgets('cambiar a móvil durante una consulta conserva la petición, la respuesta y el borrador',
      (tester) => backend.run(() async {
            final pending = Completer<http.Response>();
            backend.on('POST', '/chat', (_) => pending.future);
            await pumpChat(tester);

            await type(tester, '¿Cómo va Rivera?');
            await tester.tap(sendButton());
            await tester.pump();
            await type(tester, 'borrador');

            tester.view.physicalSize = const Size(600, 900);
            await tester.pump();
            expect(find.byType(AppBar), findsOneWidget);
            expect(find.byType(PendingMessage), findsOneWidget);

            pending.complete(chatReply('Rivera ok.', metadata: ctx(client: 'Tecnologia Rivera SL')));
            await tester.pumpAndSettle();

            expect(shows('Rivera ok.'), isTrue);
            expect(find.byType(PendingMessage), findsNothing);
            expect(find.text('Tecnologia Rivera SL'), findsOneWidget);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'borrador');
            expect(chatBodies().single, {"message": "¿Cómo va Rivera?"});
            expect(tester.takeException(), isNull);
          }));

  testWidgets('pasar de escritorio a móvil y volver conserva la conversación', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => chatReply('Rivera ok.', metadata: ctx(client: 'Tecnologia Rivera SL')));
        await pumpChat(tester);
        await send(tester, '¿Cómo va Rivera?');

        tester.view.physicalSize = const Size(600, 900);
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsOneWidget);                  // layout móvil
        expect(find.widgetWithText(UserMessage, '¿Cómo va Rivera?'), findsOneWidget);
        expect(find.text('Tecnologia Rivera SL'), findsOneWidget);

        await send(tester, '¿Y con ellos?');
        tester.view.physicalSize = const Size(1400, 1000);
        await tester.pumpAndSettle();

        expect(find.byType(UserMessage), findsNWidgets(2));
        expect(chatBodies().last, {"message": "¿Y con ellos?", "conversation_id": 42});
      }));

  testWidgets('móvil: AppBar con el nombre y Nueva conversación compacta', (tester) => backend.run(() async {
        backend.on('POST', '/chat', (_) => chatReply('ok'));
        await pumpChat(tester, desktop: false);

        expect(find.widgetWithText(AppBar, 'CRMVoice IA'), findsOneWidget);
        final reset = find.ancestor(of: find.byTooltip('Nueva conversación'), matching: find.byType(IconButton));
        expect(tester.widget<IconButton>(reset).onPressed, isNull);

        await send(tester, 'hola');
        await tester.tap(reset);
        await tester.pumpAndSettle();
        expect(find.text(ChatEmptyState.title), findsOneWidget);
      }));

  testWidgets('salir de la pantalla durante una consulta no rompe nada', (tester) => backend.run(() async {
        final pending = Completer<http.Response>();
        backend.on('POST', '/chat', (_) => pending.future);
        await pumpChat(tester);

        await type(tester, 'hola');
        await tester.tap(sendButton());
        await tester.pump();

        await tester.pumpWidget(const SizedBox());
        pending.complete(chatReply('tarde'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      }));
}
