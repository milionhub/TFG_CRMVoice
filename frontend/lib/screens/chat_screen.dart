// Chat IA (G.5): consulta del CRM en lenguaje natural.
//
// - Un único ChatView con GlobalKey: cambiar entre escritorio y móvil
//   (< 800 px) no destruye la conversación.
// - El contexto activo (cliente/contacto) sale SOLO de la metadata de la
//   respuesta; nunca del texto del usuario ni del asistente.
// - Una conversación por visita a la pantalla, sin persistencia local;
//   "Nueva conversación" empieza otra en el backend.
// - Época (_epoch): una respuesta que llega después de reiniciar se ignora.
//
// I.5.1: cabecera de página del sistema (Chat IA), estado vacío con
// identidad propia (en escritorio el composer forma parte de él) y una
// conversación limpia con el composer fijo abajo. La lógica no cambia.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/design/cv_tokens.dart';
import '../models/chat_message.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../widgets/chat/chat_composer.dart';
import '../widgets/chat/chat_context_bar.dart';
import '../widgets/chat/chat_empty_state.dart';
import '../widgets/chat/chat_message_bubble.dart';
import '../widgets/chat/chat_theme.dart';
import '../widgets/ui/cv_components.dart';
import 'home_screen.dart';

const _title = "Chat IA";
const _subtitle = "Pregunta, analiza y entiende tu CRM en lenguaje natural.";
const _newConversationLabel = "Nueva conversación";

/// Separación entre turnos de la conversación.
const double _entryGap = 26;

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // La misma instancia de ChatView en cualquier tamaño de ventana
  final _chatKey = GlobalKey<ChatViewState>();
  final _canReset = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _canReset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = AppShell.isMobile(context);

    // Shell común (I.2): barra lateral en escritorio, cabecera + menú en móvil
    return AppShell(
      currentIndex: 5,
      title: _title,
      backgroundColor: ChatColors.background,
      mobileActions: [
        ValueListenableBuilder<bool>(
          valueListenable: _canReset,
          builder: (context, canReset, _) => IconButton(
            tooltip: _newConversationLabel,
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: canReset ? () => _chatKey.currentState?.newConversation() : null,
          ),
        ),
      ],
      body: ChatView(key: _chatKey, showHeader: !isMobile, canReset: _canReset),
    );
  }
}

class ChatView extends StatefulWidget {
  /// Cabecera propia (escritorio); en móvil la pone el AppBar.
  final bool showHeader;

  /// Se mantiene al día para el botón "Nueva conversación" del AppBar.
  final ValueNotifier<bool> canReset;

  const ChatView({super.key, required this.showHeader, required this.canReset});

  @override
  State<ChatView> createState() => ChatViewState();
}

class ChatViewState extends State<ChatView> {
  final _messages = <ChatEntry>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  // Respuesta o aviso más reciente: se lleva a la vista desde su principio
  final _latestReplyKey = GlobalKey();
  // El composer cambia de sitio (estado vacío ↔ abajo) sin perder foco ni estado
  final _composerKey = GlobalKey();

  int? _conversationId;
  ChatContext _context = ChatContext.empty;
  bool _sending = false;
  String? _retryText; // pregunta del último turno fallido que se puede reintentar
  int _epoch = 0;

  bool get _canReset => _messages.isNotEmpty && !_sending;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _update(VoidCallback change) {
    setState(change);
    widget.canReset.value = _canReset;
  }

  bool get _isDesktop => MediaQuery.sizeOf(context).width >= 800;

  // ------------------------------------------------------------------
  // Envío
  // ------------------------------------------------------------------

  /// Composer, Enter y ejemplos pasan por aquí: un único camino.
  /// Solo un envío desde el composer lo vacía: un ejemplo no borra el borrador.
  void _submit(String raw, {bool fromComposer = false}) {
    if (_sending || !ChatComposer.canSend(raw)) return;
    final text = raw.trim();
    _update(() {
      _messages.add(ChatEntry.user(text));
      _retryText = null;
    });
    if (fromComposer) _input.clear();
    _request(text);
  }

  /// Reintenta la última pregunta fallida sin repetir el mensaje del usuario.
  void _retry() {
    final text = _retryText;
    if (text == null || _sending) return;
    _update(() {
      if (_messages.isNotEmpty && _messages.last.kind == ChatEntryKind.notice) _messages.removeLast();
      _retryText = null;
    });
    _request(text);
  }

  Future<void> _request(String text) async {
    final epoch = _epoch;
    final api = context.read<ApiService>();
    _update(() => _sending = true);
    _scrollToEnd();

    ChatReply? reply;
    ChatErrorKind? failure;
    try {
      reply = await api.sendChatMessage(text, conversationId: _conversationId);
    } on ChatException catch (error) {
      failure = error.kind;
    }
    // La pantalla se cerró o se empezó otra conversación mientras tanto
    if (!mounted || epoch != _epoch) return;

    final followReply = _isNearEnd;
    _update(() {
      _sending = false;
      if (reply != null) {
        _applyReply(reply, text);
      } else {
        _applyFailure(failure!, text);
      }
    });
    if (followReply) _revealLatestReply();
    if (_isDesktop) _focus.requestFocus();
  }

  void _applyReply(ChatReply reply, String text) {
    if (reply.conversationId != null) _conversationId = reply.conversationId;
    // Metadata presente: manda (null = borrado). Ausente: el contexto no se toca.
    if (reply.hasMetadata) {
      _context = ChatContext(client: reply.activeClient, contact: reply.activeContact);
    }
    if (reply.isError) {
      _messages.add(ChatEntry.notice(reply.content, action: NoticeAction.retry));
      _retryText = text;
    } else {
      _messages.add(ChatEntry.assistant(reply.content));
    }
  }

  void _applyFailure(ChatErrorKind kind, String text) {
    switch (kind) {
      case ChatErrorKind.unauthorized:
        _messages.add(const ChatEntry.notice("Tu sesión ha caducado. Vuelve a iniciar sesión.",
            action: NoticeAction.login));
      case ChatErrorKind.notFound:
        // La conversación ya no existe: se empieza otra (el reintento va sin id)
        _conversationId = null;
        _context = ChatContext.empty;
        _messages.add(const ChatEntry.notice(
            "La conversación anterior ya no está disponible. He empezado una nueva.",
            action: NoticeAction.retry));
        _retryText = text;
      case ChatErrorKind.timeout:
      case ChatErrorKind.network:
        _messages.add(const ChatEntry.notice("No se pudo enviar la consulta.", action: NoticeAction.retry));
        _retryText = text;
      case ChatErrorKind.server:
        _messages.add(const ChatEntry.notice("No se ha podido completar la consulta.", action: NoticeAction.retry));
        _retryText = text;
    }
  }

  /// "Nueva conversación": todo local a cero; la siguiente pregunta crea otra en el backend.
  void newConversation() {
    _update(() {
      _epoch++;
      _messages.clear();
      _conversationId = null;
      _context = ChatContext.empty;
      _retryText = null;
      _sending = false;
    });
    _input.clear();
  }

  // ------------------------------------------------------------------
  // Scroll
  // ------------------------------------------------------------------

  /// Cerca del final, o camino de él tras enviar (si la respuesta llega
  /// durante ese desplazamiento, el usuario no se ha movido: se sigue).
  bool get _isNearEnd =>
      _autoScrolling || !_scroll.hasClients || _scroll.position.maxScrollExtent - _scroll.offset < 160;

  bool _autoScrolling = false;

  /// Tras enviar: la pregunta (y la respuesta pendiente) a la vista.
  void _scrollToEnd() {
    _autoScrolling = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scroll.hasClients) {
        _autoScrolling = false;
        return;
      }
      await _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      _autoScrolling = false;
    });
  }

  /// Tras la respuesta: su principio arriba (una respuesta larga se lee desde el inicio).
  /// La lista es perezosa: si la respuesta aún no está construida (queda
  /// lejos del final visible), primero se salta al final y se reintenta.
  void _revealLatestReply([int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _latestReplyKey.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.0, duration: const Duration(milliseconds: 250));
      } else if (attempt < 2 && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
        _revealLatestReply(attempt + 1);
      }
    });
  }

  // ------------------------------------------------------------------
  // Vista
  // ------------------------------------------------------------------

  Widget _entry(int index) {
    final entry = _messages[index];
    final isLatest = index == _messages.length - 1;
    final Widget child;
    switch (entry.kind) {
      case ChatEntryKind.user:
        child = UserMessage(text: entry.text);
      case ChatEntryKind.assistant:
        child = AssistantMessage(markdown: entry.text);
      case ChatEntryKind.notice:
        // Solo el último aviso tiene la acción activa
        final active = isLatest && !_sending;
        child = NoticeMessage(
          text: entry.text,
          actionLabel: switch (entry.action) {
            NoticeAction.retry => active && _retryText != null ? "Reintentar" : null,
            NoticeAction.login => active ? "Iniciar sesión" : null,
            NoticeAction.none => null,
          },
          onAction: switch (entry.action) {
            NoticeAction.retry => _retry,
            NoticeAction.login => () => context.read<AuthProvider>().logout(),
            NoticeAction.none => null,
          },
        );
    }
    final isReply = isLatest && entry.kind != ChatEntryKind.user;
    return Padding(
      key: isReply ? _latestReplyKey : null,
      padding: const EdgeInsets.only(bottom: _entryGap),
      child: child,
    );
  }


  Widget _column(double gutter, Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: ChatLayout.maxColumnWidth + 2 * gutter),
        child: Padding(padding: EdgeInsets.symmetric(horizontal: gutter), child: child),
      ),
    );
  }

  /// Composer y nota de solo lectura.
  Widget _composerBlock() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChatComposer(
          key: _composerKey,
          controller: _input,
          focusNode: _focus,
          sending: _sending,
          onSend: () => _submit(_input.text, fromComposer: true),
        ),
        const SizedBox(height: 10),
        const ChatDisclaimer(),
      ],
    );
  }

  /// «Nueva conversación»: oculta sin conversación; desactivada mientras se espera.
  Widget _newConversationAction() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: _messages.isEmpty
          ? const SizedBox(key: ValueKey('no-reset'), height: 40)
          : CvSecondaryButton(
              key: const ValueKey('reset'),
              label: _newConversationLabel,
              icon: Icons.add_comment_outlined,
              onPressed: _canReset ? newConversation : null,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final gutter = ChatLayout.gutter(width);
    final showEmpty = _messages.isEmpty && !_sending;
    final desktop = widget.showHeader;
    // En escritorio, sin conversación, el composer forma parte de la composición
    final composerInEmpty = showEmpty && desktop;

    return Theme(
      data: chatTheme(),
      child: ColoredBox(
        color: ChatColors.background,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final insets = CvPageBody.insets(constraints.maxWidth);
            return Column(
              children: [
                if (desktop)
                  Padding(
                    padding: EdgeInsets.fromLTRB(insets.left, insets.top, insets.right, CvSpace.sm),
                    child: CvPageHeader(title: _title, subtitle: _subtitle, action: _newConversationAction()),
                  ),
                if (!_context.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: desktop ? CvSpace.xs : CvSpace.sm, bottom: CvSpace.xxs),
                    child: _column(
                        gutter, Align(alignment: Alignment.centerLeft, child: ChatContextBar(chatContext: _context))),
                  ),
                Expanded(
                  child: showEmpty
                      ? _emptyView(gutter, desktop, composerInEmpty ? _composerBlock() : null)
                      : _conversationView(gutter),
                ),
                if (!composerInEmpty)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: EdgeInsets.only(top: CvSpace.xs, bottom: desktop ? CvSpace.lg : CvSpace.sm),
                      child: _column(gutter, _composerBlock()),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Estado vacío equilibrado en la altura disponible (algo por encima del
  /// centro óptico); con poca altura, hace scroll.
  Widget _emptyView(double gutter, bool desktop, Widget? composer) {
    final vertical = desktop ? CvSpace.xl : CvSpace.lg;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.symmetric(vertical: vertical),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(0, constraints.maxHeight - 2 * vertical)),
          child: Align(
            alignment: const Alignment(0, -0.3),
            child: _column(
              gutter,
              ChatEmptyState(onSelected: _submit, composer: composer, compact: !desktop),
            ),
          ),
        ),
      ),
    );
  }

  /// Conversación: aparece con un fundido corto al enviar la primera pregunta.
  Widget _conversationView(double gutter) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(_epoch),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
      child: SelectionArea(
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.only(top: CvSpace.lg, bottom: CvSpace.md),
          itemCount: _messages.length + (_sending ? 1 : 0),
          itemBuilder: (context, index) => _column(
            gutter,
            index == _messages.length
                ? const Padding(padding: EdgeInsets.only(bottom: _entryGap), child: PendingMessage())
                : _entry(index),
          ),
        ),
      ),
    );
  }
}
