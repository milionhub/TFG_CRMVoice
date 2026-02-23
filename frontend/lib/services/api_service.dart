import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = "http://127.0.0.1:8000";

  /// Llama al endpoint GET /ping
  static Future<String> ping() async {
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
  static Future<Map<String, dynamic>> analyzeText(String text) async {
    final url = Uri.parse("$baseUrl/process-text");

    final response = await http.post(
      url,
      headers: {
        "Content-Type": "application/json",
      },
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
  static Future<Map<String, dynamic>> uploadAudio({
    required List<int> bytes,
    required String filename,
  }) async {
    final url = Uri.parse("$baseUrl/process-audio");

    final request = http.MultipartRequest("POST", url);
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

  static Future<List<dynamic>> getActivities({
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

  final response = await http.get(uri);

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["activities"];
  } else {
    throw Exception("Error al obtener actividades");
  }



}

static Future<Map<String, dynamic>> createActivity(
    Map<String, dynamic> data) async {

  final response = await http.post(
    Uri.parse("$baseUrl/activities"),
    headers: {"Content-Type": "application/json"},
    body: jsonEncode(data),
  );

  return jsonDecode(response.body);
}

static Future<List<dynamic>> getClients() async {
  final response = await http.get(
    Uri.parse("$baseUrl/clients"),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["clients"];
  } else {
    throw Exception("Error cargando clientes");
  }
}

static Future<List<dynamic>> getActivityTypes() async {
  final response = await http.get(
    Uri.parse("$baseUrl/activity-types"),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data["activity_types"];
  } else {
    throw Exception("Error cargando acciones");
  }
}
}


