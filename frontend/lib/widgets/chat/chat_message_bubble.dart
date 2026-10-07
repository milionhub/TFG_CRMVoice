// Elementos de la conversación: mensaje del usuario, respuesta del asistente,
// aviso (error) y respuesta pendiente.
//
// I.5.1: el usuario en una burbuja discreta (primarySoft) a la derecha; el
// asistente sin burbuja, con su símbolo y etiqueta, directamente sobre el
// fondo; el aviso y la espera, alineados con el texto del asistente.
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/design/cv_tokens.dart';
import 'chat_identity.dart';
import 'chat_theme.dart';

/// Sangría del contenido del asistente: alinea el texto tras su símbolo.
const double _assistantIndent = 34;

class _AssistantLabel extends StatelessWidget {
  const _AssistantLabel();

  static const name = "CRMVoice IA";

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        AssistantMark(size: 24),
        SizedBox(width: 10),
        Text(
          name,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ChatColors.textSecondary),
        ),
      ],
    );
  }
}

/// Mensaje del usuario: a la derecha, fondo primarySoft y texto oscuro;
/// hasta el 78 % de la columna (560 px como mucho).
class UserMessage extends StatelessWidget {
  final String text;

  const UserMessage({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.maxWidth * 0.78;
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: max > 560 ? 560 : max),
            child: Semantics(
              label: "Tú",
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  color: ChatColors.accentSoft,
                  border: Border.all(color: CvColors.primary.withValues(alpha: 0.22)),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(5),
                  ),
                ),
                child: Text(text, style: const TextStyle(color: ChatColors.textPrimary, fontSize: 15, height: 1.5)),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Respuesta del asistente: símbolo + «CRMVoice IA» y el Markdown con la
/// hoja de estilos del chat, sin burbuja.
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
      label: _AssistantLabel.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _AssistantLabel(),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: _assistantIndent),
            child: MarkdownBody(
              data: markdown,
              styleSheet: chatMarkdownStyle(),
              onTapLink: (text, href, title) {},
              imageBuilder: _imageAsText,
            ),
          ),
        ],
      ),
    );
  }
}

/// Aviso (error del backend o de la petición) con una acción opcional. Va
/// en línea, en el turno del asistente: no borra la pregunta del usuario.
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
      child: Padding(
        padding: const EdgeInsets.only(left: _assistantIndent),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: ChatColors.noticeBackground,
            borderRadius: BorderRadius.circular(ChatLayout.radius),
            border: Border.all(color: ChatColors.noticeBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1, right: 10),
                child: Icon(Icons.error_outline_rounded, size: 19, color: CvColors.warning),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text, style: const TextStyle(color: ChatColors.noticeText, fontSize: 14.5, height: 1.45)),
                    if (actionLabel != null && onAction != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: OutlinedButton(
                          onPressed: onAction,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: ChatColors.noticeText,
                            backgroundColor: CvColors.surface,
                            side: const BorderSide(color: ChatColors.noticeBorder),
                            minimumSize: const Size(44, 38),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CvRadius.sm)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(actionLabel == "Reintentar" ? Icons.refresh_rounded : Icons.login_rounded,
                                  size: 17),
                              const SizedBox(width: 6),
                              Text(actionLabel!),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Respuesta en curso: «Analizando tu CRM…» con la onda en movimiento (sin
/// pasos inventados: la API no los envía).
class PendingMessage extends StatelessWidget {
  const PendingMessage({super.key});

  static const text = "Analizando tu CRM…";

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: text,
      excludeSemantics: true,
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AssistantLabel(),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.only(left: _assistantIndent),
            child: Row(
              children: [
                ThinkingWave(),
                SizedBox(width: 10),
                Text(text, style: TextStyle(color: ChatColors.textSecondary, fontSize: 14.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
