import 'package:google_sign_in/google_sign_in.dart';

class GoogleAuthService {

  // Instancia única: en web el plugin conecta sus eventos (botón oficial,
  // One Tap) con onCurrentUserChanged de UNA instancia de GoogleSignIn.
  GoogleAuthService._();

  static final GoogleAuthService _instance = GoogleAuthService._();

  factory GoogleAuthService() => _instance;

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email',
      'profile'
    ],
    signInOption: SignInOption.standard,
  );

  /// Cuenta Google autenticada (botón oficial, One Tap o signIn en móvil).
  Stream<GoogleSignInAccount?> get onCurrentUserChanged =>
      _googleSignIn.onCurrentUserChanged;

  /// ID token de Google de la cuenta: es lo que verifica el backend.
  Future<String?> getIdToken(GoogleSignInAccount account) async {
    try {
      final auth = await account.authentication;
      return auth.idToken;
    } catch (e) {
      print("Google idToken error: $e");
      return null;
    }
  }

  /// Login interactivo en plataformas NO web (en web se usa renderButton).
  /// El resultado llega por [onCurrentUserChanged].
  Future<void> signIn() async {

    try {

      await _googleSignIn.signIn();

    } catch (e) {

      print("Google login error: $e");

    }

  }

  /// One Tap / inicio silencioso. El resultado llega por [onCurrentUserChanged].
  Future<void> signInSilently() async {

    try {

      await _googleSignIn.signInSilently(
        suppressErrors: true,
      );

    } catch (e) {

      // Sin sesión previa de Google: no es un error

    }

  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }
}
