// Caja de escritura del chat: varias líneas, Enter envía y Shift+Enter salta
// de línea (teclado físico), límite de 2000 caracteres como el backend.
// I.5.1: superficie más alta y cómoda, anillo de foco suave y botón de
// enviar integrado; debajo, la nota de solo lectura (ChatDisclaimer).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design/cv_tokens.dart';
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
  static const placeholder = "Pregunta cualquier cosa sobre tu CRM…";

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
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.onKeyEvent = null;
      oldWidget.focusNode.removeListener(_onFocus);
      widget.focusNode.onKeyEvent = _handleKey;
      widget.focusNode.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    widget.focusNode.onKeyEvent = null;
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() => setState(() {});

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
    final focused = widget.focusNode.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
      decoration: BoxDecoration(
        color: ChatColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: focused ? CvColors.primaryDark : CvColors.borderStrong, width: focused ? 1.4 : 1),
        boxShadow: [
          if (focused) BoxShadow(color: CvColors.primary.withValues(alpha: 0.16), spreadRadius: 3),
          const BoxShadow(color: Color(0x0A172033), blurRadius: 16, offset: Offset(0, 6)),
        ],
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
              style: const TextStyle(fontSize: 15.5, height: 1.45, color: ChatColors.textPrimary),
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
                hintStyle: TextStyle(color: CvColors.textPlaceholder),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: (context, value, _) {
              final canSend = ChatComposer.canSend(value.text) && !widget.sending;
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: IconButton.filled(
                  tooltip: "Enviar",
                  onPressed: canSend ? widget.onSend : null,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    backgroundColor: CvColors.primaryDark,
                    disabledBackgroundColor: CvColors.primarySoft,
                    hoverColor: CvColors.primaryStrong,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.control + 2)),
                  ),
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: widget.sending
                        ? const SizedBox(
                            key: ValueKey('sending'),
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: CvColors.primaryDark),
                          )
                        : Icon(
                            Icons.arrow_upward_rounded,
                            key: ValueKey(canSend),
                            size: 21,
                            color: canSend ? Colors.white : CvColors.textPlaceholder,
                          ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Nota discreta bajo el composer: el asistente solo lee el CRM.
class ChatDisclaimer extends StatelessWidget {
  static const text = "CRMVoice IA consulta tus datos, pero no los modifica.";

  const ChatDisclaimer({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.lock_outline_rounded, size: 13, color: CvColors.textSecondary),
        SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.35, color: CvColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
