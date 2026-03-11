import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'package:http/http.dart' as http;
import'../services/google_auth_service.dart';

class AuthProvider extends ChangeNotifier {
  String? _token;
  String? _userName;
  String? _userEmail;
  Map<String, dynamic>? _user;
  bool _isLoading = false;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  String? get token => _token;
  String? get userName => _userName;
  String? get userEmail => _userEmail;

  Map<String, dynamic>? get user => _user;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _token != null;
  final String baseUrl = "http://127.0.0.1:8000";

  /// ==========================
  /// INIT (cargar sesión guardada)
  /// ==========================
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString("auth_token");

    if (savedToken != null) {
      _setToken(savedToken);
    }

    _initialized = true;
    notifyListeners();
  }

  /// ==========================
  /// LOGIN
  /// ==========================
  Future<bool> login(
      String email,
      String password,
      bool rememberMe,
  ) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await ApiService.login(email, password);

      final newToken = response["access_token"];

      _setToken(newToken);

      _userEmail = email;
      _userName = email.split("@")[0];

      if (rememberMe) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString("auth_token", newToken);
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// ==========================
  /// REGISTER
  /// ==========================
  Future<bool> register(
      String nombre,
      String email,
      String password,
      bool rememberMe,
  ) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response =
          await ApiService.register(nombre, email, password);

      final newToken = response["access_token"];

      _setToken(newToken);

      if (rememberMe) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString("auth_token", newToken);
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// ==========================
  /// LOGOUT
  /// ==========================
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("auth_token");

    _token = null;
    _user = null;

    notifyListeners();
  }

  /// ==========================
  /// PRIVATE: set token + decode
  /// ==========================
  void _setToken(String token) {
    _token = token;

    final parts = token.split(".");
    if (parts.length == 3) {
      final payload = jsonDecode(
        utf8.decode(
          base64Url.decode(
            base64Url.normalize(parts[1]),
          ),
        ),
      );
      _user = payload;
    }
  }

 Future<bool> googleLogin(String accessToken) async {

    final response = await http.post(
      Uri.parse("$baseUrl/auth/google"),
      headers: {
        "Content-Type": "application/json",
      },
      body: jsonEncode({
        "accessToken": accessToken,
      }),
    );

    if (response.statusCode != 200) {
      print("Google login backend error: ${response.body}");
      return false;
    }

    final data = jsonDecode(response.body);

    _token = data["access_token"];
    _userName = data["user"]["nombre"];
    _userEmail = data["user"]["email"];

    notifyListeners();

    return true;
  }

  Future<bool> tryGoogleAutoLogin() async {

    final googleAuth = GoogleAuthService();

    final result = await googleAuth.signInSilently();

    if (result == null) return false;

    final accessToken = result["accessToken"];

    return await googleLogin(accessToken);
  }
}