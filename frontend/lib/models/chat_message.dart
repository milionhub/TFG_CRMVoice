// Modelos del chat (G.5): solo lo que la pantalla necesita.
//
// El contexto activo (cliente/contacto) llega SIEMPRE del backend en
// `metadata` estructurada; nunca se deduce del texto del usuario ni del
// asistente.
import 'package:flutter/foundation.dart';

/// Cliente o contacto del CRM tal como lo devuelve el backend: {id, name}.
@immutable
class ChatEntity {
  final int id;
  final String name;

  const ChatEntity({required this.id, required this.name});

  /// `null` si el valor no tiene la forma esperada.
  static ChatEntity? fromJson(Object? json) {
    if (json is Map && json['id'] is int && json['name'] is String) {
      return ChatEntity(id: json['id'] as int, name: json['name'] as String);
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is ChatEntity && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Contexto activo de la conversación (cliente y, opcionalmente, contacto).
@immutable
class ChatContext {
  final ChatEntity? client;
  final ChatEntity? contact;

  const ChatContext({this.client, this.contact});

  static const empty = ChatContext();

  bool get isEmpty => client == null && contact == null;

  @override
  bool operator ==(Object other) => other is ChatContext && other.client == client && other.contact == contact;

  @override
  int get hashCode => Object.hash(client, contact);
}

enum ChatEntryKind { user, assistant, notice }

/// Acción que ofrece un aviso (solo la del último turno está activa).
enum NoticeAction { none, retry, login }

/// Un elemento de la conversación tal como se muestra.
@immutable
class ChatEntry {
  final ChatEntryKind kind;
  final String text;
  final NoticeAction action;

  const ChatEntry.user(this.text)
      : kind = ChatEntryKind.user,
        action = NoticeAction.none;

  const ChatEntry.assistant(this.text)
      : kind = ChatEntryKind.assistant,
        action = NoticeAction.none;

  const ChatEntry.notice(this.text, {this.action = NoticeAction.none}) : kind = ChatEntryKind.notice;
}
