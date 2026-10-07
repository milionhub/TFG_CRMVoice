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

  /// I.6.3: la última sesión terminó por caducidad (401). La pantalla de
  /// acceso lo muestra UNA vez ([takeSessionExpiredNotice]); un login
  /// correcto lo descarta. Solo presentación: no cambia la expiración.
  bool _sessionExpiredNotice = false;

  /// Devuelve si hay que avisar de la sesión caducada y lo consume.
  bool takeSessionExpiredNotice() {
    final pending = _sessionExpiredNotice;
    _sessionExpiredNotice = false;
    return pending;
  }
  final String baseUrl = ApiService.baseUrl;

  /// Tras un logout explícito no se vuelve a entrar automáticamente con Google.
  /// Se persiste (SharedPreferences → localStorage en web) para que sobreviva
  /// a F5: Google One Tap/FedCM puede reautenticar aunque se haya hecho signOut.
  static const String _googleAutoLoginDisabledKey = "google_auto_login_disabled";
  bool _googleAutoLoginSuppressed = false;

  bool get isGoogleAutoLoginSuppressed => _googleAutoLoginSuppressed;

  /// ==========================
  /// INIT (cargar sesión guardada)
  /// ==========================
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString("auth_token");

    _googleAutoLoginSuppressed =
        prefs.getBool(_googleAutoLoginDisabledKey) ?? false;

    if (savedToken != null) {

      if (_isExpired(savedToken)) {
        await prefs.remove("auth_token");
      } else {
        _setToken(savedToken);

        final valid = await _loadCurrentUser();

        // El backend rechaza el token → sesión no válida
        if (!valid) {
          await prefs.remove("auth_token");
          _clearSession();
        }
      }
    }

    _initialized = true;
    notifyListeners();
  }

  /// Rellena nombre/email desde GET /me.
  /// Devuelve false solo si el backend rechaza el token.
  Future<bool> _loadCurrentUser() async {
    if (_token == null) return false;

    try {
      final me = await ApiService.fetchMe(_token!);

      if (me == null) return false;

      _userName = me["nombre"];
      _userEmail = me["email"];
    } catch (e) {
      // Sin conexión: mantenemos la sesión con el email del token
      _userEmail ??= _user?["email"];
    }

    return true;
  }

  bool _isExpired(String token) {
    try {
      final payload = _decodePayload(token);
      final exp = payload?["exp"];

      if (exp is! num) return false;

      final expiry =
          DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);

      return DateTime.now().isAfter(expiry);
    } catch (_) {
      return true;
    }
  }

  void _clearSession() {
    _token = null;
    _user = null;
    _userName = null;
    _userEmail = null;
  }

  /// Un login iniciado por el usuario vuelve a permitir One Tap en el futuro
  Future<void> _allowGoogleAutoLogin() async {
    _googleAutoLoginSuppressed = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_googleAutoLoginDisabledKey);
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

      final user = response["user"];
      _userEmail = user?["email"] ?? email;
      _userName = user?["nombre"] ?? email.split("@")[0];
      await _allowGoogleAutoLogin();

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

      // /register no devuelve el usuario → lo pedimos al backend
      _userName = nombre;
      _userEmail = email;
      await _loadCurrentUser();
      await _allowGoogleAutoLogin();

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
  /// FE-02 (H.6): el backend ha rechazado el token (caducado o revocado).
  /// La sesión se cierra en memoria al instante (la app vuelve a la pantalla
  /// de acceso) y se borra el token guardado. No es un "cerrar sesión" del
  /// usuario: no se toca la sesión de Google ni el inicio automático.
  Future<void> expireSession() async {
    if (_token == null) return;
    _clearSession();
    _sessionExpiredNotice = true;
    _isLoading = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("auth_token");
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("auth_token");

    // Cerrar también la sesión de Google (si la hay) y no reintentar
    // el login automático, tampoco tras recargar (F5)
    _googleAutoLoginSuppressed = true;
    await prefs.setBool(_googleAutoLoginDisabledKey, true);

    try{
      final googleAuth = GoogleAuthService();
      await googleAuth.signOut();
    } catch (e) {
      debugPrint("Google logout error: $e");
    }

    _clearSession();
    _isLoading = false;

    notifyListeners();
  }

  /// ==========================
  /// PRIVATE: set token + decode
  /// ==========================
  void _setToken(String token) {
    _token = token;
    _sessionExpiredNotice = false;

    try {
      _user = _decodePayload(token);
    } catch (_) {
      _user = null;
    }
  }

  Map<String, dynamic>? _decodePayload(String token) {
    final parts = token.split(".");
    if (parts.length != 3) return null;

    return jsonDecode(
      utf8.decode(
        base64Url.decode(
          base64Url.normalize(parts[1]),
        ),
      ),
    ) as Map<String, dynamic>;
  }

 /// Envía el ID token de Google al backend, que lo verifica (firma, aud, exp...)
 Future<bool> googleLogin(String idToken, {bool rememberMe = true}) async {

    final http.Response response;

    try {
      response = await http.post(
        Uri.parse("$baseUrl/auth/google"),
        headers: {
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "idToken": idToken,
        }),
      );
    } catch (e) {
      debugPrint("Google login connection error: $e");
      return false;
    }

    if (response.statusCode != 200) {
      debugPrint("Google login backend error: ${response.body}");
      return false;
    }

    final data = jsonDecode(response.body);
    final newToken = data["access_token"];

    _setToken(newToken);
    _userName = data["user"]["nombre"];
    _userEmail = data["user"]["email"];
    await _allowGoogleAutoLogin();

    if (rememberMe) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("auth_token", newToken);
    }

    notifyListeners();

    return true;
  }

  /// Lanza One Tap / inicio silencioso. Si Google devuelve una cuenta,
  /// AuthScreen la recibe por onCurrentUserChanged y llama a [googleLogin].
  Future<void> tryGoogleAutoLogin() async {

    if (_googleAutoLoginSuppressed || isAuthenticated) return;

    await GoogleAuthService().signInSilently();
  }
}