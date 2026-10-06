import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/chat_message.dart';
import '../models/action_draft.dart';
import '../models/crm.dart';
import '../providers/auth_provider.dart';
import 'api_errors.dart';

export 'api_errors.dart';

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

  /// FE-02 (H.6): un 401 en una petición autenticada significa que el token
  /// ha caducado o se ha revocado. Se cierra la sesión en toda la app (vuelve
  /// a la pantalla de acceso), igual desde el CRM, la voz o el chat.
  Future<void> _checkSession(int statusCode) async {
    if (statusCode == 401 && auth.isAuthenticated) await auth.expireSession();
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

  Future<List<dynamic>> getActivities({
  int? clientId,
  int? actionId,
  String? dateFrom,
  String? dateTo,
  String? status,
}) async {

  final queryParams = <String, String>{};

  if (status != null) {
    queryParams["status"] = status;
  }

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

  await _checkSession(response.statusCode);
  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["activities"];
  } else {
    throw Exception("Error al obtener actividades");
  }



}

Future<List<dynamic>> getClients() async {
  final response = await http.get(
    Uri.parse("$baseUrl/clients"),
    headers: _headers(),
  );

  await _checkSession(response.statusCode);
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

  await _checkSession(response.statusCode);
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

  await _checkSession(response.statusCode);
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

  await _checkSession(response.statusCode);
  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["products"];
  } else {
    throw Exception("Error cargando productos");
  }
}

Future<void> deleteActivity(int id) async {
  await _send('DELETE', '/activities/$id');
}

  // ===================================================================
  // CRM funcional (H.3): contratos H.2 tipados
  // ===================================================================

  static const Duration crmTimeout = Duration(seconds: 20);

  /// Petición JSON al backend. Devuelve el cuerpo decodificado (UTF-8) o
  /// lanza [ApiException] con un mensaje apto para el usuario.
  Future<dynamic> _send(String method, String path,
      {Map<String, String>? query, Object? body, Duration timeout = crmTimeout}) async {
    final uri = Uri.parse("$baseUrl$path")
        .replace(queryParameters: query == null || query.isEmpty ? null : query);
    final http.Response response;
    final headers = _headers();
    final payload = body == null ? null : jsonEncode(body);
    try {
      final Future<http.Response> future = switch (method) {
        'GET' => http.get(uri, headers: headers),
        'POST' => http.post(uri, headers: headers, body: payload),
        'PUT' => http.put(uri, headers: headers, body: payload),
        'PATCH' => http.patch(uri, headers: headers, body: payload),
        'DELETE' => http.delete(uri, headers: headers),
        _ => throw ArgumentError.value(method, 'method'),
      };
      response = await future.timeout(timeout);
    } on TimeoutException {
      throw const ApiException(ApiErrorKind.network,
          'El servidor ha tardado demasiado en responder. Inténtalo de nuevo.');
    } catch (_) {
      throw const ApiException.network();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _checkSession(response.statusCode);
      throw ApiException.fromResponse(response.statusCode, response.bodyBytes);
    }
    if (response.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const ApiException(ApiErrorKind.server, 'Respuesta no válida del servidor.');
    }
  }

  Map<String, dynamic> _object(Object? data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    throw const ApiException(ApiErrorKind.server, 'Respuesta no válida del servidor.');
  }

  // ---------- Catálogo ----------

  Future<List<CatalogItem>> clientItems() async =>
      CatalogItem.listFrom(_object(await _send('GET', '/clients'))['clients']);

  Future<List<CatalogItem>> contactItems(int clientId) async => CatalogItem.listFrom(
      _object(await _send('GET', '/contacts', query: {'client_id': '$clientId'}))['contacts']);

  Future<List<CatalogItem>> activityTypeItems() async =>
      CatalogItem.listFrom(_object(await _send('GET', '/activity-types'))['activity_types']);

  Future<List<CatalogItem>> productItems() async =>
      CatalogItem.listFrom(_object(await _send('GET', '/products'))['products']);

  // ---------- Clientes y contactos ----------

  /// GET /clients?q= (búsqueda del backend: razón social o alias).
  Future<List<ClientSummary>> searchClients({String? query}) async {
    final q = query?.trim() ?? '';
    final data = _object(await _send('GET', '/clients', query: q.isEmpty ? null : {'q': q}));
    final list = data['clients'];
    return list is List ? list.map(ClientSummary.fromJson).whereType<ClientSummary>().toList() : const [];
  }

  Future<ClientDetail> getClientDetail(int clientId) async {
    try {
      return ClientDetail.fromJson(_object(await _send('GET', '/clients/$clientId')));
    } on FormatException {
      throw const ApiException(ApiErrorKind.server, 'Respuesta no válida del servidor.');
    }
  }

  Future<ClientSaveResult> createClient(ClientInput input) async =>
      ClientSaveResult.fromJson(_object(await _send('POST', '/clients', body: input.toJson())));

  Future<ClientSaveResult> updateClient(int clientId, ClientInput input) async =>
      ClientSaveResult.fromJson(_object(await _send('PUT', '/clients/$clientId', body: input.toJson())));

  Future<Contact> createContact(int clientId, ContactInput input) async =>
      _contact(await _send('POST', '/contacts', body: input.toJson(clientId: clientId)));

  /// Sin client_id: un contacto no cambia de cliente.
  Future<Contact> updateContact(int contactId, ContactInput input) async =>
      _contact(await _send('PUT', '/contacts/$contactId', body: input.toJson()));

  Contact _contact(Object? data) =>
      Contact.fromJson(data) ??
      (throw const ApiException(ApiErrorKind.server, 'Respuesta no válida del servidor.'));

  // ---------- Actividades V2 ----------

  Future<List<CrmActivity>> listActivities({
    int? clientId,
    ActivityStatus? status,
    String? dateFrom,
    String? dateTo,
  }) async {
    final data = _object(await _send('GET', '/activities', query: {
      if (clientId != null) 'client_id': '$clientId',
      if (status != null) 'status': status.api,
      if (dateFrom != null) 'date_from': dateFrom,
      if (dateTo != null) 'date_to': dateTo,
    }));
    return CrmActivity.listFrom(data['activities']);
  }

  Future<CrmActivity> createActivityV2(ActivityInput input) async =>
      _activity(await _send('POST', '/activities', body: input.toJson()));

  Future<CrmActivity> updateActivityV2(int id, ActivityInput input) async =>
      _activity(await _send('PUT', '/activities/$id', body: input.toJson()));

  /// PATCH /activities/{id}: solo el estado.
  Future<CrmActivity> setActivityStatus(int id, ActivityStatus status) async =>
      _activity(await _send('PATCH', '/activities/$id', body: {'status': status.api}));

  CrmActivity _activity(Object? data) =>
      CrmActivity.fromJson(data) ??
      (throw const ApiException(ApiErrorKind.server, 'Respuesta no válida del servidor.'));

  // ---------- Home ----------

  /// GET /dashboard: métricas del comercial (H.5.2).
  Future<DashboardData> getDashboard() async => DashboardData.fromJson(_object(await _send('GET', '/dashboard')));

  // ---------- Ventas ----------

  Future<List<Sale>> createSales(SaleCreateInput input) async =>
      Sale.listFrom(_object(await _send('POST', '/sales', body: input.toJson()))['sales']);

  Future<Sale> updateSale(int saleId, SaleUpdateInput input) async =>
      Sale.fromJson(await _send('PUT', '/sales/$saleId', body: input.toJson())) ??
      (throw const ApiException(ApiErrorKind.server, 'Respuesta no válida del servidor.'));

  Future<void> deleteSale(int saleId) async {
    await _send('DELETE', '/sales/$saleId');
  }

  // ===================================================================
  // Voice V2 (H.4): Action Engine de H.2 (borradores confirmables)
  // ===================================================================

  /// Whisper local + interpretación: puede tardar bastante más que un CRUD.
  static const Duration actionTimeout = Duration(seconds: 120);

  /// Límite del backend (voice_pipeline.MAX_AUDIO_BYTES).
  static const int maxAudioBytes = 10 * 1024 * 1024;

  /// POST /actions/interpret-audio (multipart, campo "file").
  Future<VoiceInterpretation> interpretAudio({required List<int> bytes, required String filename}) async {
    final request = http.MultipartRequest("POST", Uri.parse("$baseUrl/actions/interpret-audio"));
    if (auth.token != null) request.headers['Authorization'] = 'Bearer ${auth.token}';
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final http.Response response;
    try {
      response = await http.Response.fromStream(await request.send().timeout(actionTimeout))
          .timeout(actionTimeout);
    } on TimeoutException {
      throw const ApiException(ApiErrorKind.network,
          'El servidor ha tardado demasiado en procesar el audio. Inténtalo de nuevo.');
    } catch (_) {
      throw const ApiException.network();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _checkSession(response.statusCode);
      throw ApiException.fromResponse(response.statusCode, response.bodyBytes);
    }
    try {
      final data = _object(jsonDecode(utf8.decode(response.bodyBytes)));
      final draft = ActionDraft.tryParse(data['draft']);
      if (draft == null) throw const FormatException('sin borrador');
      return VoiceInterpretation(data['transcript'] is String ? data['transcript'] as String : '', draft);
    } catch (_) {
      throw const ApiException(ApiErrorKind.server, 'Respuesta no válida del servidor.');
    }
  }

  /// POST /actions/interpret (texto escrito o transcripción corregida).
  Future<ActionDraft> interpretText(String text) async =>
      _draft(await _send('POST', '/actions/interpret', body: {'text': text}, timeout: actionTimeout));

  Future<ActionDraft> getDraft(String id) async =>
      _draft(await _send('GET', '/actions/${Uri.encodeComponent(id)}'));

  /// PATCH /actions/{id}: ediciones tipadas por acción, con la revisión vista.
  Future<ActionDraft> patchDraft(String id, int revision, Map<String, dynamic> edits) async => _draft(
      await _send('PATCH', '/actions/${Uri.encodeComponent(id)}', body: {'revision': revision, 'edits': edits}));

  /// POST /actions/{id}/confirm: SOLO la revisión (nunca datos de negocio).
  Future<ConfirmOutcome> confirmDraft(String id, int revision) async {
    final data = _object(await _send('POST', '/actions/${Uri.encodeComponent(id)}/confirm',
        body: {'revision': revision}, timeout: actionTimeout));
    return ConfirmOutcome(ActionResult.fromJson(data['result']), ActionDraft.tryParse(data['draft']));
  }

  Future<ActionDraft> cancelDraft(String id) async =>
      _draft(await _send('POST', '/actions/${Uri.encodeComponent(id)}/cancel'));

  ActionDraft _draft(Object? data) =>
      ActionDraft.tryParse(data) ??
      (throw const ApiException(ApiErrorKind.server, 'Respuesta no válida del servidor.'));

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
        await _checkSession(401);
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
