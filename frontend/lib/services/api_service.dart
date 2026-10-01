import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import '../models/chat_message.dart';
import '../providers/auth_provider.dart';

class ApiService {
  final AuthProvider auth;

 
  /// Única configuración de la URL del backend.
  /// Se puede cambiar al arrancar: --dart-define=API_BASE_URL=http://host:puerto
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

   ApiService(this.auth);
   
   Map<String, String> _headers() {
      final token = auth.token;

      return {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
    }

  /// Llama al endpoint GET /ping
  Future<String> ping() async {
    final url = Uri.parse("$baseUrl/ping");
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data["message"] ?? "ok";
    } else {
      throw Exception("Error conexión backend");
    }
  }

  /// Llama al endpoint POST /process-text
  Future<Map<String, dynamic>> analyzeText(String text) async {
    final url = Uri.parse("$baseUrl/process-text");

    final response = await http.post(
      url,
      headers: _headers(),
      body: jsonEncode({
        "text": text,
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception("Error al procesar el texto");
    }
  }

   /// 🔴 NUEVO: POST /process-audio (multipart/form-data)
  Future<Map<String, dynamic>> uploadAudio({
    required List<int> bytes,
    required String filename,
  }) async {
    final url = Uri.parse("$baseUrl/process-audio");

    final request = http.MultipartRequest("POST", url);
    if (auth.token != null) {
      request.headers['Authorization'] = 'Bearer ${auth.token}';
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        'file', // nombre del campo en FastAPI
        bytes,
        filename: filename,
      ),
    );

    final streamedResponse = await request.send();
    final body = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode == 200) {
      return jsonDecode(body) as Map<String, dynamic>;
    } else {
      throw Exception(
          "Error al enviar audio (${streamedResponse.statusCode}): $body");
    }
  }

  Future<List<dynamic>> getActivities({
  int? clientId,
  int? actionId,
  String? dateFrom,
  String? dateTo,
}) async {

  final queryParams = <String, String>{};

  if (clientId != null) {
    queryParams["client_id"] = clientId.toString();
  }

  if (actionId != null) {
    queryParams["action_id"] = actionId.toString();
  }

  if (dateFrom != null && dateFrom.isNotEmpty) {
    queryParams["date_from"] = dateFrom;
  }

  if (dateTo != null && dateTo.isNotEmpty) {
    queryParams["date_to"] = dateTo;
  }

  final uri = Uri.parse("$baseUrl/activities")
      .replace(queryParameters: queryParams);

  final response = await http.get(uri, headers: _headers());

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["activities"];
  } else {
    throw Exception("Error al obtener actividades");
  }



}

Future<Map<String, dynamic>> getActivity(int id) async {
  final response = await http.get(
    Uri.parse("$baseUrl/activities/$id"),
    headers: _headers(),
  );

  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    throw Exception("Error cargando actividad");
  }
}

Future<Map<String, dynamic>> createActivity(
    Map<String, dynamic> data) async {

  final response = await http.post(
    Uri.parse("$baseUrl/activities"),
    headers: _headers(),
    body: jsonEncode(data),
  );

  return jsonDecode(response.body);
}
Future<List<dynamic>> getClients() async {
  final response = await http.get(
    Uri.parse("$baseUrl/clients"),
    headers: _headers(),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["clients"];
  } else {
    throw Exception("Error cargando clientes");
  }
}

Future<List<dynamic>> getContacts({int? clientId}) async {
  final queryParams = <String, String>{};

  if (clientId != null) {
    queryParams["client_id"] = clientId.toString();
  }

  final uri = Uri.parse("$baseUrl/contacts")
      .replace(queryParameters: queryParams);

  final response = await http.get(uri, headers: _headers());

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["contacts"];
  } else {
    throw Exception("Error cargando contactos");
  }
}

Future<List<dynamic>> getActivityTypes() async {
  final response = await http.get(
    Uri.parse("$baseUrl/activity-types"),
    headers: _headers(),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["activity_types"];
  } else {
    throw Exception("Error cargando acciones");
  }
}


static Future<Map<String, dynamic>> login(
    String email, String password) async {

  final response = await http.post(
    Uri.parse("$baseUrl/login"),
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "email": email,
      "password": password,
    }),
  );

  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    throw Exception("Login error");
  }
}

static Future<Map<String, dynamic>> register(
    String nombre, String email, String password) async {

  final response = await http.post(
    Uri.parse("$baseUrl/register"),
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "nombre": nombre,
      "email": email,
      "password": password,
    }),
  );

  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    throw Exception("Register error");
  }
}

/// GET /me con un token concreto (restauración de sesión).
/// Devuelve null si el token no es válido (401/403); lanza en otros errores.
static Future<Map<String, dynamic>?> fetchMe(String token) async {

  final response = await http.get(
    Uri.parse("$baseUrl/me"),
    headers: {"Authorization": "Bearer $token"},
  ).timeout(const Duration(seconds: 5));

  if (response.statusCode == 200) {
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  if (response.statusCode == 401 || response.statusCode == 403) {
    return null;
  }

  throw Exception("Error obteniendo usuario (${response.statusCode})");
}

Future<List<dynamic>> getProducts() async {
  final response = await http.get(
    Uri.parse("$baseUrl/products"),
    headers: _headers(),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["products"];
  } else {
    throw Exception("Error cargando productos");
  }
}

Future<bool> updateActivity(int id, Map<String, dynamic> data) async {
  final response = await http.put(
    Uri.parse("$baseUrl/activities/$id"),
    headers: _headers(),
    body: jsonEncode(data),
  );

  
  if (response.statusCode == 200) {
    final json = jsonDecode(response.body);
    return json["success"] == true;
  } else {
    debugPrint(response.body);
    return false;
  }
}

Future<void> deleteActivity(int id) async {
  final response = await http.delete(
    Uri.parse("$baseUrl/activities/$id"),
    headers: _headers(),
  );

  if (response.statusCode != 200) {
    throw Exception("Error borrando actividad");
  }
}

  // ===================================================================
  // Chat IA (G.5)
  // ===================================================================

  /// Tiempo máximo de una consulta al chat (el backend se acota en ~30 s).
  static const Duration chatTimeout = Duration(seconds: 45);

  /// POST /chat. Devuelve la respuesta tipada o lanza [ChatException]
  /// (sin texto del servidor ni de la excepción original).
  Future<ChatReply> sendChatMessage(String message, {int? conversationId}) async {
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse("$baseUrl/chat"),
            headers: _headers(),
            body: jsonEncode({
              "message": message,
              if (conversationId != null) "conversation_id": conversationId,
            }),
          )
          .timeout(chatTimeout);
    } on TimeoutException {
      throw const ChatException(ChatErrorKind.timeout);
    } catch (_) {
      throw const ChatException(ChatErrorKind.network);
    }

    switch (response.statusCode) {
      case 200:
        return ChatReply.parse(response.bodyBytes);
      case 401:
        throw const ChatException(ChatErrorKind.unauthorized);
      case 404:
        throw const ChatException(ChatErrorKind.notFound);
      default:
        throw const ChatException(ChatErrorKind.server);
    }
  }
}

enum ChatErrorKind { unauthorized, notFound, timeout, network, server }

/// Fallo de una consulta al chat, solo con su tipo (nunca detalles del servidor).
class ChatException implements Exception {
  final ChatErrorKind kind;

  const ChatException(this.kind);

  @override
  String toString() => 'ChatException(${kind.name})';
}

/// Respuesta de POST /chat.
///
/// [hasMetadata] distingue "metadata con cliente/contacto a null" (el
/// backend ha borrado el contexto) de "sin metadata" (no hay que tocarlo).
class ChatReply {
  final bool isError;
  final String content;
  final int? conversationId;
  final bool hasMetadata;
  final ChatEntity? activeClient;
  final ChatEntity? activeContact;

  const ChatReply({
    required this.isError,
    required this.content,
    this.conversationId,
    this.hasMetadata = false,
    this.activeClient,
    this.activeContact,
  });

  /// JSON en UTF-8 por definición (no depende del charset de la cabecera).
  factory ChatReply.parse(List<int> bodyBytes) {
    try {
      final data = jsonDecode(utf8.decode(bodyBytes));
      if (data is! Map || data["content"] is! String) {
        throw const FormatException("respuesta del chat sin content");
      }
      final metadata = data["metadata"];
      final conversationId = data["conversation_id"];
      return ChatReply(
        isError: data["type"] == "error",
        content: data["content"] as String,
        conversationId: conversationId is int ? conversationId : null,
        hasMetadata: metadata is Map,
        activeClient: metadata is Map ? ChatEntity.fromJson(metadata["active_client"]) : null,
        activeContact: metadata is Map ? ChatEntity.fromJson(metadata["active_contact"]) : null,
      );
    } on ChatException {
      rethrow;
    } catch (_) {
      throw const ChatException(ChatErrorKind.server);
    }
  }
}
