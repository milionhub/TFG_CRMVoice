import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';

class GoogleAuthService {

  /// OAuth Client ID (tipo Web) de Google. Se configura al arrancar:
  /// --dart-define=GOOGLE_CLIENT_ID=xxxx.apps.googleusercontent.com
  /// Debe coincidir con GOOGLE_CLIENT_ID del backend.
  static const String clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');

  /// En web, sin Client ID no se ofrece el login con Google.
  static bool get isConfigured => !kIsWeb || clientId.isNotEmpty;

  // Instancia única: en web el plugin conecta sus eventos (botón oficial,
  // One Tap) con onCurrentUserChanged de UNA instancia de GoogleSignIn.
  GoogleAuthService._();

  static final GoogleAuthService _instance = GoogleAuthService._();

  factory GoogleAuthService() => _instance;

  // Solo se crea si hay configuración (en web, crearla inicializa el plugin)
  late final GoogleSignIn? _googleSignIn = isConfigured
      ? GoogleSignIn(
          clientId: kIsWeb ? clientId : null,
          scopes: [
            'email',
            'profile'
          ],
          signInOption: SignInOption.standard,
        )
      : null;

  /// Cuenta Google autenticada (botón oficial, One Tap o signIn en móvil).
  Stream<GoogleSignInAccount?> get onCurrentUserChanged =>
      _googleSignIn?.onCurrentUserChanged ??
      const Stream<GoogleSignInAccount?>.empty();

  /// ID token de Google de la cuenta: es lo que verifica el backend.
  Future<String?> getIdToken(GoogleSignInAccount account) async {
    try {
      final auth = await account.authentication;
      return auth.idToken;
    } catch (e) {
      debugPrint("Google idToken error: $e");
      return null;
    }
  }

  /// Login interactivo en plataformas NO web (en web se usa renderButton).
  /// El resultado llega por [onCurrentUserChanged].
  Future<void> signIn() async {

    try {

      await _googleSignIn?.signIn();

    } catch (e) {

      debugPrint("Google login error: $e");

    }

  }

  /// One Tap / inicio silencioso. El resultado llega por [onCurrentUserChanged].
  Future<void> signInSilently() async {

    try {

      await _googleSignIn?.signInSilently(
        suppressErrors: true,
      );

    } catch (e) {

      // Sin sesión previa de Google: no es un error

    }

  }

  Future<void> signOut() async {
    try {
      await _googleSignIn?.signOut();
    } catch (_) {}
  }
}
