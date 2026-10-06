// Chat IA (G.5): consulta del CRM en lenguaje natural.
//
// - Un único ChatView con GlobalKey: cambiar entre escritorio y móvil
//   (< 800 px) no destruye la conversación.
// - El contexto activo (cliente/contacto) sale SOLO de la metadata de la
//   respuesta; nunca del texto del usuario ni del asistente.
// - Una conversación por visita a la pantalla, sin persistencia local;
//   "Nueva conversación" empieza otra en el backend.
// - Época (_epoch): una respuesta que llega después de reiniciar se ignora.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../widgets/chat/chat_composer.dart';
import '../widgets/chat/chat_context_bar.dart';
import '../widgets/chat/chat_empty_state.dart';
import '../widgets/chat/chat_message_bubble.dart';
import '../widgets/chat/chat_theme.dart';
import 'home_screen.dart';

const _title = "CRMVoice IA";
const _subtitle = "Consulta tu CRM en lenguaje natural";
const _newConversationLabel = "Nueva conversación";

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
    final isMobile = MediaQuery.sizeOf(context).width < 800;

    return Scaffold(
      backgroundColor: ChatColors.background,
      drawer: isMobile ? const MobileDrawer() : null,
      appBar: isMobile
          ? AppBar(
              backgroundColor: ChatColors.surface,
              foregroundColor: ChatColors.textPrimary,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              shape: const Border(bottom: BorderSide(color: ChatColors.border)),
              title: const Text(_title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
              actions: [
                ValueListenableBuilder<bool>(
                  valueListenable: _canReset,
                  builder: (context, canReset, _) => IconButton(
                    tooltip: _newConversationLabel,
                    icon: const Icon(Icons.add_comment_outlined),
                    onPressed: canReset ? () => _chatKey.currentState?.newConversation() : null,
                  ),
                ),
              ],
            )
          : null,
      body: Row(
        children: [
          if (!isMobile) const Sidebar(currentIndex: 4),
          Expanded(
            child: SafeArea(
              child: ChatView(key: _chatKey, showHeader: !isMobile, canReset: _canReset),
            ),
          ),
        ],
      ),
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

  bool get _isNearEnd =>
      !_scroll.hasClients || _scroll.position.maxScrollExtent - _scroll.offset < 160;

  /// Tras enviar: la pregunta (y la respuesta pendiente) a la vista.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  /// Tras la respuesta: su principio arriba (una respuesta larga se lee desde el inicio).
  void _revealLatestReply() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _latestReplyKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(target, alignment: 0.0, duration: const Duration(milliseconds: 250));
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
      padding: const EdgeInsets.only(bottom: 14),
      child: child,
    );
  }

  Widget _column(double gutter, Widget child) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ChatLayout.maxColumnWidth + 64),
        child: Padding(padding: EdgeInsets.symmetric(horizontal: gutter), child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final gutter = ChatLayout.gutter(width);
    final showEmpty = _messages.isEmpty && !_sending;

    return Theme(
      data: chatTheme(),
      child: ColoredBox(
        color: ChatColors.background,
        child: Column(
          children: [
            if (widget.showHeader)
              _ChatHeader(onNewConversation: _canReset ? newConversation : null),
            if (!_context.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: widget.showHeader ? 0 : 12, bottom: 4),
                child: _column(gutter, Align(alignment: Alignment.centerLeft, child: ChatContextBar(chatContext: _context))),
              ),
            Expanded(
              child: showEmpty
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: _column(gutter, ChatEmptyState(onSelected: _submit)),
                    )
                  : SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        itemCount: _messages.length + (_sending ? 1 : 0),
                        itemBuilder: (context, index) => _column(
                          gutter,
                          index == _messages.length
                              ? const Padding(padding: EdgeInsets.only(bottom: 14), child: PendingMessage())
                              : _entry(index),
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: width < 800 ? 8 : 20, top: 4),
              child: _column(
                gutter,
                ChatComposer(
                  controller: _input,
                  focusNode: _focus,
                  sending: _sending,
                  onSend: () => _submit(_input.text, fromComposer: true),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  final VoidCallback? onNewConversation;

  const _ChatHeader({required this.onNewConversation});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: ChatColors.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.insights_outlined, color: ChatColors.accent),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_title,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: ChatColors.textPrimary)),
                SizedBox(height: 2),
                Text(_subtitle, style: TextStyle(fontSize: 13, color: ChatColors.textSecondary)),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: onNewConversation,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            label: const Text(_newConversationLabel),
            style: OutlinedButton.styleFrom(
              foregroundColor: ChatColors.accent,
              side: const BorderSide(color: ChatColors.border),
              minimumSize: const Size(44, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }
}
