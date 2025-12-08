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
}

