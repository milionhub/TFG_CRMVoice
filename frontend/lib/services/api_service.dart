import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class ApiService {
  final AuthProvider auth;

 
  static const String baseUrl = "http://127.0.0.1:8000";

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
    print(response.body);
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

}