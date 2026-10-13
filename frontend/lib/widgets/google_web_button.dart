// Solo se compila en web: auth_screen.dart lo importa condicionalmente
// (en el resto de plataformas usa google_web_button_stub.dart).
import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as gsi_web;

/// Botón oficial de Google (GIS). Al pulsarlo, la cuenta llega por
/// GoogleSignIn.onCurrentUserChanged con un ID token.
///
/// Ocupa el mismo ancho que el formulario (como "Entrar"), dentro del rango
/// que admite Google (200–400 px). La altura la fija Google: `large` = 40 px.
Widget buildGoogleWebButton() {
  return LayoutBuilder(
    builder: (context, constraints) {
      final int width = constraints.maxWidth.isFinite
          ? constraints.maxWidth.clamp(200.0, 400.0).round()
          : 300;

      return gsi_web.renderButton(configuration: _configurationFor(width));
    },
  );
}

// renderButton usa config.hashCode como Key: reutilizar la misma instancia
// por ancho evita que Google vuelva a pintar el botón en cada rebuild.
final Map<int, gsi_web.GSIButtonConfiguration> _configurations = {};

gsi_web.GSIButtonConfiguration _configurationFor(int width) {
  return _configurations.putIfAbsent(
    width,
    () => gsi_web.GSIButtonConfiguration(
      theme: gsi_web.GSIButtonTheme.outline,
      size: gsi_web.GSIButtonSize.large,
      text: gsi_web.GSIButtonText.continueWith,
      shape: gsi_web.GSIButtonShape.rectangular,
      minimumWidth: width.toDouble(),
    ),
  );
}
