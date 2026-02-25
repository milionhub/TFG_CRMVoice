import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  String? _token;
  Map<String, dynamic>? _user;
  bool _isLoading = false;

  String? get token => _token;
  Map<String, dynamic>? get user => _user;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _token != null;

  /// ==========================
  /// INIT (cargar sesión guardada)
  /// ==========================
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString("auth_token");

    if (savedToken != null) {
      _token = savedToken;

      // Opcional: decodificar payload JWT
      final parts = savedToken.split(".");
      if (parts.length == 3) {
        final payload =
            jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
        _user = payload;
      }
    }

    notifyListeners();
  }

  /// ==========================
  /// LOGIN
  /// ==========================
  Future<bool> login(String email, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await ApiService.login(email, password);

      _token = response["access_token"];

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("auth_token", _token!);

      await init();

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
      String nombre, String email, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response =
          await ApiService.register(nombre, email, password);

      _token = response["access_token"];

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("auth_token", _token!);

      await init();

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
}