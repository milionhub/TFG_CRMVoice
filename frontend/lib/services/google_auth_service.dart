import 'package:google_sign_in/google_sign_in.dart';

class GoogleAuthService {

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email',
      'profile'
    ],
    signInOption: SignInOption.standard,
  );

  Future<Map<String, dynamic>?> signIn() async {

    try {

      final account = await _googleSignIn.signIn();

      if (account == null) return null;

      final auth = await account.authentication;

      return {
        "accessToken": auth.accessToken,
      };

    } catch (e) {

      print("Google login error: $e");
      return null;

    }

  }

  Future<Map<String, dynamic>?> signInSilently() async {

    try {

      final account = await _googleSignIn.signInSilently(
        suppressErrors: true,
      );

      if (account == null) return null;

      final auth = await account.authentication;

      return {
        "accessToken": auth.accessToken,
      };

    } catch (e) {

      return null;

    }

  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }
}