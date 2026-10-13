// Contexto activo de la conversación, SOLO a partir de la metadata del backend.
// Sin botón para quitarlo: no hay endpoint; se borra escribiendo "Olvida ese
// cliente" o con "Nueva conversación".
import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import 'chat_theme.dart';

class ChatContextBar extends StatelessWidget {
  final ChatContext chatContext;

  const ChatContextBar({super.key, required this.chatContext});

  static const hint =
      "Las preguntas con «ellos» o «él» se refieren a este contexto. Escribe «Olvida ese cliente» para quitarlo.";

  @override
  Widget build(BuildContext context) {
    if (chatContext.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: hint,
      child: Semantics(
        container: true,
        label: "Contexto de la conversación",
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text("Contexto", style: TextStyle(fontSize: 12, color: ChatColors.textSecondary)),
            if (chatContext.client != null)
              _ContextChip(icon: Icons.business_outlined, label: chatContext.client!.name, kind: "Cliente"),
            if (chatContext.contact != null)
              _ContextChip(icon: Icons.person_outline, label: chatContext.contact!.name, kind: "Contacto"),
          ],
        ),
      ),
    );
  }
}

class _ContextChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String kind;

  const _ContextChip({required this.icon, required this.label, required this.kind});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: "$kind: $label",
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: ChatColors.accentSoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: ChatColors.accent),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ChatColors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
