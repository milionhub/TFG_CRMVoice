// Caja de escritura del chat: varias líneas, Enter envía y Shift+Enter salta
// de línea (teclado físico), límite de 2000 caracteres como el backend.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_theme.dart';

class ChatComposer extends StatefulWidget {
  /// Mismo límite que el backend (ChatRequest.message).
  static const maxLength = 2000;

  /// Longitud como la cuenta el backend (Pydantic: code points), no en
  /// unidades UTF-16 (String.length) ni en grafemas (contador del TextField):
  /// un emoji es 1, una "é" descompuesta (NFD) son 2.
  static int lengthOf(String text) => text.runes.length;

  /// Lo que se puede enviar: algo más que espacios y dentro del límite.
  static bool canSend(String text) {
    final trimmed = text.trim();
    return trimmed.isNotEmpty && lengthOf(trimmed) <= maxLength;
  }
  static const placeholder = "Pregunta sobre clientes, actividades, productos…";

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final VoidCallback onSend;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.onKeyEvent = _handleKey;
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.onKeyEvent = null;
      widget.focusNode.onKeyEvent = _handleKey;
    }
  }

  @override
  void dispose() {
    widget.focusNode.onKeyEvent = null;
    super.dispose();
  }

  /// Enter (sin Shift y sin composición IME en curso) envía; lo demás sigue su curso.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (event is! KeyDownEvent || !isEnter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (widget.controller.value.composing.isValid) return KeyEventResult.ignored;
    widget.onSend();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
      decoration: BoxDecoration(
        color: ChatColors.surface,
        borderRadius: BorderRadius.circular(ChatLayout.radius),
        border: Border.all(color: ChatColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              minLines: 1,
              maxLines: 6,
              // Tope de escritura (en grafemas); el límite real del envío es canSend
              maxLength: ChatComposer.maxLength,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 15, height: 1.4, color: ChatColors.textPrimary),
              buildCounter: (context, {required currentLength, required isFocused, required maxLength}) {
                // Contador en code points, como el backend; en rojo si no se puede enviar
                final length = ChatComposer.lengthOf(widget.controller.text);
                if (length <= 1800) return null;
                final over = ChatComposer.lengthOf(widget.controller.text.trim()) > ChatComposer.maxLength;
                return Text(
                  over ? "$length / ${ChatComposer.maxLength} · demasiado largo" : "$length / ${ChatComposer.maxLength}",
                  style: TextStyle(fontSize: 12, color: over ? ChatColors.error : ChatColors.textSecondary),
                );
              },
              decoration: const InputDecoration(
                hintText: ChatComposer.placeholder,
                hintStyle: TextStyle(color: ChatColors.textSecondary),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: (context, value, _) {
              final canSend = ChatComposer.canSend(value.text) && !widget.sending;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: IconButton.filled(
                  tooltip: "Enviar",
                  onPressed: canSend ? widget.onSend : null,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    backgroundColor: ChatColors.accent,
                    disabledBackgroundColor: ChatColors.accentSoft,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: widget.sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: ChatColors.accent),
                        )
                      : Icon(Icons.arrow_upward_rounded, color: canSend ? Colors.white : ChatColors.textSecondary),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
