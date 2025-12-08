import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = "http://127.0.0.1:8000";

  static Future<String> ping() async {
    final url = Uri.parse("$baseUrl/ping");

    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data["message"];
    } else {
      throw Exception("Error conexión backend");
    }
  }
}
