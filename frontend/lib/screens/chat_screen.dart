import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../core/app_colors.dart';
import 'home_screen.dart';

class ChatMessage {
  final String content;
  final bool isUser;
  final String? type;
  final List<String>? actions;
  final List<dynamic>? results;
  final Map<String, dynamic>? billing;
  final Map<String, dynamic>? summary;

  ChatMessage({
    required this.content,
    required this.isUser,
    this.type,
    this.actions,
    this.results,
    this.billing,
    this.summary,
  });
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;

    if (isMobile) {
      return const _MobileLayoutChat();
    } else {
      return const _DesktopLayoutChat();
    }
  }
}

class _DesktopLayoutChat extends StatelessWidget {
  const _DesktopLayoutChat();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          const Sidebar(currentIndex: 3),
          const Expanded(
            child: SafeArea(
              child: ChatContent(),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileLayoutChat extends StatelessWidget {
  const _MobileLayoutChat();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: const MobileDrawer(),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const Text("Asistente IA"),
      ),
      body: const SafeArea(
        child: ChatContent(),
      ),
    );
  }
}

class ChatContent extends StatefulWidget {
  const ChatContent({super.key});

  @override
  State<ChatContent> createState() => _ChatContentState();
}

class _ChatContentState extends State<ChatContent> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _loading = false;

  String? _activeClient;
  String? _pendingIntent;

  final String baseUrl = "http://127.0.0.1:8000";

  @override
  void initState() {
    super.initState();

    _messages.add(
      ChatMessage(
        content:
            "Hola 👋\n\nSoy tu asistente CRM.\n\nPuedo ayudarte con:\n\n• Preparar reuniones\n• Analizar clientes\n• Consultar facturación\n• Buscar actividades",
        isUser: false,
      ),
    );
  }

 Future<void> _sendMessage() async {

    String text = _controller.text.trim();

    // 🔹 Si hay intención pendiente → construir mensaje completo
    if (_pendingIntent != null) {
      text = "$_pendingIntent $text";
      _pendingIntent = null;
    }

    if (text.isEmpty) return;

    // 🔹 Detectar cliente activo
    if (text.toLowerCase().contains("cliente")) {
      final parts = text.split("cliente");
      if (parts.length > 1) {
        _activeClient = parts.last.trim();
      }
    }

    setState(() {
      _messages.add(ChatMessage(content: text, isUser: true));
      _loading = true;
    });

    _controller.clear();
    _scrollToBottom();

    final token = context.read<AuthProvider>().token;

    try {
      final response = await http.post(
        Uri.parse("$baseUrl/chat"),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $token"
        },
        body: jsonEncode({"message": text}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        setState(() {
          _messages.add(
            ChatMessage(
              content: data["content"],
              isUser: false,
              type: data["type"],
              actions: data["metadata"]?["suggested_actions"] != null
                  ? List<String>.from(data["metadata"]["suggested_actions"])
                  : null,
              results: data["metadata"]?["results"],
              billing: data["metadata"]?["billing"],
              summary: data["metadata"]?["summary"],
            ),
          );
        });
      } else {
        setState(() {
          _messages.add(
            ChatMessage(
              content: "Error del servidor",
              isUser: false,
            ),
          );
        });
      }
    } catch (e) {
      setState(() {
        _messages.add(
          ChatMessage(
            content: "Error de conexión",
            isUser: false,
          ),
        );
      });
    }

    setState(() => _loading = false);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _buildMessage(ChatMessage message) {
    return Row(
      mainAxisAlignment:
          message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        if (!message.isUser)
          const Padding(
            padding: EdgeInsets.only(left: 16, right: 8, top: 6),
            child: CircleAvatar(
              radius: 14,
              backgroundColor: AppColors.primary,
              child: Icon(Icons.smart_toy, size: 16, color: Colors.white),
            ),
          ),

        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              /// MENSAJE
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.all(14),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.55,
                ),
                decoration: BoxDecoration(
                  color: message.isUser
                      ? AppColors.primary
                      : Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: message.isUser
                        ? const Radius.circular(18)
                        : const Radius.circular(4),
                    bottomRight: message.isUser
                        ? const Radius.circular(4)
                        : const Radius.circular(18),
                  ),
                    border: Border.all(
                      color: AppColors.border,
                    ),
                ),
                child: message.isUser
                    ? Text(
                        message.content,
                        style: const TextStyle(color: Colors.white),
                      )
                    : message.type == "billing_summary"
                      ? _buildBillingCard(message)
                      : message.type == "semantic_search"
                          ? _buildActivitiesList(message)
                          : message.type == "client_summary"
                            ? _buildClientSummary(message)
                          : MarkdownBody(
                            data: message.content,
                            styleSheet: MarkdownStyleSheet(
                              p: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
                              h3: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
              ),

              /// BOTONES SUGERIDOS
              if (!message.isUser && message.actions != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 8,
                    children: message.actions!
                      .map((action) {
                        
                        final config = actionConfig[action];

                        if (config == null) return const SizedBox();

                        final label = config["label"]!;
                        final baseMessage = config["message"]!;

                        return OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            side: BorderSide(color: AppColors.border),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                          ),
                          onPressed: () {

                            String finalMessage = baseMessage;

                            if (_activeClient != null) {
                              finalMessage = "$baseMessage $_activeClient";
                            }

                            _pendingIntent = null;

                            _controller.text = finalMessage;
                            _sendMessage();
                          },
                          child: Text(label),
                        );
                      })
                      .toList(),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildClientSummary(ChatMessage message) {
    final summary = message.summary;

    if (summary == null) {
      return const Text("No hay datos");
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          /// 🧾 HEADER
          const Text(
            "📊 Resumen del cliente",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary, 
            ),
          ),

          const SizedBox(height: 14),

          /// 🟢 ESTADO
          if (summary["status"] != null)
            _summaryBlock(
              title: "Estado",
              content: summary["status"],
            ),

          /// 🔵 ACTIVIDAD
          if (summary["activity"] != null)
            _summaryBlock(
              title: "Actividad",
              content: summary["activity"],
            ),

          /// 🟣 OPORTUNIDADES
          if (summary["opportunities"] != null &&
              (summary["opportunities"] as List).isNotEmpty)
            _summaryList(
              title: "Oportunidades",
              items: summary["opportunities"],
            ),
        ],
      ),
    );
  }

  Widget _summaryBlock({
    required String title,
    required String content,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(content),
        ],
      ),
    );
  }

  Widget _summaryList({
    required String title,
    required List items,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          ...items.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              "• $e",
              style: const TextStyle(
                color: AppColors.primary,
              ),
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildActivitiesList(ChatMessage message) {
    final results = message.results ?? [];

    if (results.isEmpty) {
      return const Text("No hay actividades");
    }

    return Column(
      children: results.map((r) {

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              /// 🟣 TIPO (ej: llamada, visita, etc.)
              if (r["tipo"] != null)
                Text(
                  r["tipo"],
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),

              const SizedBox(height: 6),

              /// 🟢 CLIENTE
              if (r["cliente"] != null)
                Text(
                  r["cliente"],
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),

              const SizedBox(height: 8),

              /// 📝 COMENTARIO
              Text(
                r["comentario"] ?? "",
                style: const TextStyle(fontSize: 14),
              ),

              const SizedBox(height: 8),

              /// 📅 FECHA
              if (r["fecha"] != null)
                Text(
                  r["fecha"],
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                  ),
                ),
            ],
          ),
        );

      }).toList(),
    );
  }

  Widget _buildBillingCard(ChatMessage message) {
    final billing = message.billing;

    if (billing == null) {
      return const Text("No hay datos");
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          /// 🧾 TÍTULO
          const Text(
            "💰 Facturación",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),

          const SizedBox(height: 12),

          /// 💵 TOTAL
          Text(
            "${billing["total_facturado"]} €",
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppColors.primary,
            ),
          ),

          const SizedBox(height: 12),

          /// 📊 DETALLES
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _metric("Facturas", billing["total_facturas"]),
              _metric("Ticket medio", billing["ticket_medio"]),
            ],
          ),

          const SizedBox(height: 10),

          /// 📅 ÚLTIMA FACTURA
          if (billing["ultima_factura"] != null)
            Text(
              "Última factura: ${billing["ultima_factura"]}",
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _metric(String label, dynamic value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "$value",
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.primary,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActions() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        alignment: WrapAlignment.start,
        spacing: 12,
        runSpacing: 12,
        children: [

          _quickButton("Preparar reunión", "prepara una reunion con"),
          _quickButton("Resumen cliente", "resumen cliente"),
          _quickButton("Facturación cliente", "facturacion cliente"),
          _quickButton("Buscar actividad", "buscar actividades de"),
        ],
      ),
    );
  }

  Widget _quickButton(String label, String message) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.primary,
        elevation: 0,
        side: const BorderSide(color: Color(0xffe5e7eb)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      onPressed: () {

        if (_activeClient != null) {
          // ya tenemos cliente → ejecutar directo
          _controller.text = "$message $_activeClient";
          _pendingIntent = null;
          _sendMessage();
        } else {
          // NO enviar todavía → solo guardar intención
          _pendingIntent = message;

          setState(() {
            _messages.add(
              ChatMessage(
                content: _questionForIntent(message),
                isUser: false,
              ),
            );
          });
        }

      },
      child: Text(label),
    );
  }

  String _questionForIntent(String intent) {
    if (intent.contains("facturacion")) {
      return "¿De qué cliente quieres consultar la facturación?";
    } else if (intent.contains("reunion")) {
      return "¿Para qué cliente quieres preparar la reunión?";
    } else if (intent.contains("resumen")) {
      return "¿De qué cliente quieres el resumen?";
    } else if (intent.contains("actividad")) {
      return "¿Qué cliente quieres consultar?";
    }
    return "¿Para qué cliente?";
  }

  Map<String, Map<String, String>> actionConfig = {
    "prepare_meeting": {
      "label": "Preparar reunión",
      "message": "prepara una reunion con"
    },
    "client_summary": {
      "label": "Resumen cliente",
      "message": "resumen cliente"
    },
    "billing_query": {
      "label": "Facturación",
      "message": "facturacion cliente"
    },
    "semantic_search": {
      "label": "Buscar actividad",
      "message": "buscar actividades de"
    },
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [

       
    /// HEADER
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Row(
          children: [
            const Icon(Icons.smart_toy, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Text(
              "Asistente CRM",
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),

      /// CLIENTE ACTIVO
      if (_activeClient != null)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.assistantBubble,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              const Icon(Icons.business, size: 16),
              const SizedBox(width: 6),
              Text(
                "Cliente activo: $_activeClient",
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

      const Divider(height: 1),

        

        /// CHAT
        Expanded(
          child: _messages.length == 1
              ? Center(
                child: Padding(padding: const EdgeInsets.only(bottom: 120),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildMessage(_messages.first),
                      const SizedBox(height: 16),
                      _buildQuickActions(),
                    ],
                  ),
                )
                  
              )
          : ListView.builder(
            controller: _scrollController,
            itemCount: _messages.length,
            itemBuilder: (_, index) {
              return _buildMessage(_messages[index]);
            },
          ),
        ),

       if (_loading)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.assistantBubble,
                  child: Icon(
                    Icons.smart_toy,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.assistantBubble,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: const TypingIndicator(),
                ),
              ],
            ),
          ),

        /// INPUT
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Colors.white,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: "Pregunta algo sobre tu CRM...",
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send),
                color: AppColors.primary,
                onPressed: _sendMessage,
              )
            ],
          ),
        )
      ],
    );
  }

}

class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {

  late AnimationController _controller;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _dot(double delay) {
    return FadeTransition(
      opacity: Tween(begin: 0.2, end: 1.0).animate(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(delay, delay + 0.4, curve: Curves.easeInOut),
        ),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: CircleAvatar(
          radius: 3,
          backgroundColor: Colors.black54,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _dot(0.0),
        _dot(0.2),
        _dot(0.4),
      ],
    );
  }
}