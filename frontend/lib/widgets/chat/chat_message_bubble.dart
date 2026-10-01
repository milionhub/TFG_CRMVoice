// Elementos de la conversación: mensaje del usuario, respuesta del asistente,
// aviso (error) y respuesta pendiente.
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'chat_theme.dart';

class _AssistantLabel extends StatelessWidget {
  const _AssistantLabel();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 6),
      child: Text(
        "CRMVoice",
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ChatColors.textSecondary),
      ),
    );
  }
}

/// Mensaje del usuario: a la derecha, pizarra oscura, hasta el 82 % de la columna.
class UserMessage extends StatelessWidget {
  final String text;

  const UserMessage({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.82),
          child: Semantics(
            label: "Tú",
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: ChatColors.accent,
                borderRadius: BorderRadius.circular(ChatLayout.radius),
              ),
              child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.45)),
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantCard extends StatelessWidget {
  final Widget child;
  final Color background;
  final Color border;

  const _AssistantCard({required this.child, this.background = ChatColors.surface, this.border = ChatColors.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(ChatLayout.radius),
        border: Border.all(color: border),
      ),
      child: child,
    );
  }
}

/// Respuesta del asistente: Markdown con la hoja de estilos del chat.
/// Los enlaces no abren nada y las imágenes no se cargan: el contenido del
/// modelo nunca decide peticiones de red ni lecturas de archivos locales.
class AssistantMessage extends StatelessWidget {
  final String markdown;

  const AssistantMessage({super.key, required this.markdown});

  /// En lugar de la imagen, su texto alternativo (o nada).
  static Widget _imageAsText(Uri uri, String? title, String? alt) {
    if (alt == null || alt.trim().isEmpty) return const SizedBox.shrink();
    // Text.rich: flutter_markdown fusiona el texto en línea leyendo Text.textSpan
    // (con un Text normal es null y el render falla)
    return Text.rich(
        TextSpan(text: alt, style: const TextStyle(color: ChatColors.textSecondary, fontStyle: FontStyle.italic)));
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: "CRMVoice",
      child: _AssistantCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AssistantLabel(),
            MarkdownBody(
              data: markdown,
              styleSheet: chatMarkdownStyle(),
              onTapLink: (text, href, title) {},
              imageBuilder: _imageAsText,
            ),
          ],
        ),
      ),
    );
  }
}

/// Aviso (error del backend o de la petición) con una acción opcional.
class NoticeMessage extends StatelessWidget {
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  const NoticeMessage({super.key, required this.text, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    // Región viva: el lector de pantalla anuncia el aviso cuando aparece
    return Semantics(
      container: true,
      liveRegion: true,
      child: _notice(),
    );
  }

  Widget _notice() {
    return _AssistantCard(
      background: ChatColors.noticeBackground,
      border: ChatColors.noticeBorder,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1, right: 10),
            child: Icon(Icons.info_outline, size: 20, color: ChatColors.noticeText),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(color: ChatColors.noticeText, fontSize: 14.5, height: 1.45)),
                if (actionLabel != null && onAction != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton(
                      onPressed: onAction,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ChatColors.noticeText,
                        side: const BorderSide(color: ChatColors.noticeBorder),
                        minimumSize: const Size(44, 40),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text(actionLabel!),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Respuesta en curso: sin pasos inventados (la API no los envía).
class PendingMessage extends StatelessWidget {
  const PendingMessage({super.key});

  static const text = "Consultando tu CRM…";

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: text,
      child: const _AssistantCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AssistantLabel(),
            Row(
              children: [
                _TypingDots(),
                SizedBox(width: 10),
                Text(text, style: TextStyle(color: ChatColors.textSecondary, fontSize: 14.5)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _dot(double start) {
    return FadeTransition(
      opacity: Tween(begin: 0.25, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Interval(start, start + 0.4, curve: Curves.easeInOut)),
      ),
      child: Container(
        width: 6,
        height: 6,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: const BoxDecoration(color: ChatColors.accent, shape: BoxShape.circle),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(child: Row(mainAxisSize: MainAxisSize.min, children: [_dot(0), _dot(0.2), _dot(0.4)]));
  }
}
