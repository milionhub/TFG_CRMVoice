import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart' show GoogleSignInAccount;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/google_web_button_stub.dart'
    if (dart.library.js_interop) '../widgets/google_web_button.dart';
import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import '../services/google_auth_service.dart';
import '../widgets/auth/auth_components.dart';
import '../widgets/brand/crm_voice_brand.dart';
import '../widgets/brand/crm_voice_wave_background.dart';

/// Login / Register (I.1.1). Composición centrada: marca + eslogan, panel
/// con el formulario y enlace para cambiar de modo. En móvil el formulario
/// va directamente sobre el fondo (sin tarjeta).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

/// Separación entre bloques label+input (el label queda a 8 px de su input)
const double _fieldGap = CvSpace.xl + 2;

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {

  bool isLogin = true;
  bool rememberMe = true;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  /// Error de autenticación mostrado en línea sobre el CTA
  String? _authError;

  final _nombreController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  /// Cuenta Google autenticada (botón oficial, One Tap o signIn en móvil)
  StreamSubscription<GoogleSignInAccount?>? _googleUserSubscription;
  bool _googleLoginInProgress = false;

  @override
  void initState() {
    super.initState();

    _googleUserSubscription =
        GoogleAuthService().onCurrentUserChanged.listen(_onGoogleAccount);

    // Aparición suave del contenido
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.015),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    _animationController.forward();

    /// AUTO LOGIN GOOGLE
    WidgetsBinding.instance.addPostFrameCallback((_) async {

      final auth = context.read<AuthProvider>();

      await auth.tryGoogleAutoLogin();

    });
  }

  /// Envía el ID token de Google al backend (única vía de login con Google)
  Future<void> _onGoogleAccount(GoogleSignInAccount? account) async {
    if (account == null || _googleLoginInProgress) return;

    _googleLoginInProgress = true;

    try {
      final idToken = await GoogleAuthService().getIdToken(account);

      if (!mounted) return;

      final success = idToken != null &&
          await context.read<AuthProvider>().googleLogin(
            idToken,
            rememberMe: rememberMe,
          );

      if (!success && mounted) {
        setState(() => _authError = "No se pudo iniciar sesión con Google.");
      }
    } finally {
      _googleLoginInProgress = false;
    }
  }

  @override
  void dispose() {
    _googleUserSubscription?.cancel();
    _nombreController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  bool _isValidEmail(String email) {
    final regex = RegExp(r"^[\w-.]+@([\w-]+\.)+[\w-]{2,4}$");
    return regex.hasMatch(email);
  }

  void _switchMode(bool login) {
    // Cada modo monta su propio Form (estado de validación nuevo)
    setState(() {
      isLogin = login;
      _authError = null;
      _obscurePassword = true;
      _obscureConfirmPassword = true;

      _nombreController.clear();
      _emailController.clear();
      _passwordController.clear();
      _confirmPasswordController.clear();
    });
  }

  void _clearAuthError(String _) {
    if (_authError != null) setState(() => _authError = null);
  }

  Future<void> _submit(BuildContext formContext) async {
    final auth = context.read<AuthProvider>();
    if (auth.isLoading) return;

    FocusScope.of(context).unfocus();

    if (!Form.of(formContext).validate()) return;

    setState(() => _authError = null);

    bool success;

    if (isLogin) {

      success = await auth.login(
        _emailController.text.trim(),
        _passwordController.text.trim(),
        rememberMe,
      );

    } else {

      success = await auth.register(
        _nombreController.text.trim(),
        _emailController.text.trim(),
        _passwordController.text.trim(),
        rememberMe,
      );

    }

    if (!success && mounted) {
      setState(() {
        _authError = isLogin
            ? "Credenciales incorrectas"
            : "No se pudo crear la cuenta. Revisa los datos e inténtalo de nuevo.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {

    final auth = context.watch<AuthProvider>();

    return Theme(
      data: CvTheme.light(),
      child: Scaffold(
        backgroundColor: CvColors.background,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final isMobile = width < CvBreakpoints.tablet;
            final isDesktop = width >= CvBreakpoints.desktop;

            final pagePadding = EdgeInsets.symmetric(
              horizontal: isMobile ? CvSpace.lg : CvSpace.xxl,
              vertical: isMobile ? CvSpace.xxl : CvSpace.xxxl,
            );

            return Stack(
              children: [
                Positioned.fill(
                  child: CrmVoiceWaveBackground(
                    density: CrmVoiceWaveBackground.densityFor(width),
                    clearWidth: 440 + CvSpace.xl * 2,
                  ),
                ),
                SafeArea(
                  child: LayoutBuilder(
                    builder: (context, safe) => SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: pagePadding,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: (safe.maxHeight - pagePadding.vertical)
                              .clamp(0.0, double.infinity),
                        ),
                        child: Center(
                          child: FadeTransition(
                            opacity: _fadeAnimation,
                            child: SlideTransition(
                              position: _slideAnimation,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 440),
                                child: _buildContent(
                                  auth,
                                  isMobile: isMobile,
                                  isDesktop: isDesktop,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent(
    AuthProvider auth, {
    required bool isMobile,
    required bool isDesktop,
  }) {
    final form = AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.02),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey(isLogin),
          child: _buildForm(auth, isMobile: isMobile),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [

        /// MARCA + ESLOGAN
        Center(child: CrmVoiceWordmark(markSize: isMobile ? 32 : 36)),
        const SizedBox(height: CvSpace.sm),
        Text(
          "Tu CRM. Ahora también te escucha.",
          textAlign: TextAlign.center,
          style: CvText.body.copyWith(fontSize: 14),
        ),

        SizedBox(height: isMobile ? CvSpace.xxl : CvSpace.xxl + 4),

        /// PANEL DEL FORMULARIO (en móvil, sin tarjeta)
        if (isMobile)
          form
        else
          Container(
            padding: EdgeInsets.all(isDesktop ? 40 : CvSpace.xxl),
            decoration: BoxDecoration(
              color: CvColors.surface,
              borderRadius: BorderRadius.circular(CvRadius.card),
              border: Border.all(color: CvColors.border),
              boxShadow: CvShadows.panel,
            ),
            child: form,
          ),

        const SizedBox(height: CvSpace.lg),

        /// CAMBIO DE MODO
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Wrap(
            key: ValueKey(isLogin),
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                isLogin ? "¿Aún no tienes cuenta?" : "¿Ya tienes cuenta?",
                style: CvText.body.copyWith(fontSize: 14),
              ),
              AuthLinkButton(
                key: const ValueKey('auth-switch-mode'),
                label: isLogin ? "Crear cuenta" : "Inicia sesión",
                onPressed: () => _switchMode(!isLogin),
              ),
            ],
          ),
        ),

        if (!isMobile) ...[
          const SizedBox(height: CvSpace.xl),
          Text(
            "Gestiona clientes, actividades y ventas hablando de forma natural.",
            textAlign: TextAlign.center,
            style: CvText.helper,
          ),
        ],
      ],
    );
  }

  Widget _buildForm(AuthProvider auth, {required bool isMobile}) {

    return Form(
      child: AutofillGroup(
        child: Builder(
          builder: (formContext) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [

              /// CABECERA
              Text(
                isLogin ? "Bienvenido de nuevo" : "Crea tu cuenta",
                style: CvText.heading.copyWith(fontSize: isMobile ? 22 : 24),
              ),
              const SizedBox(height: CvSpace.xs - 2),
              Text(
                isLogin
                    ? "Accede a tu CRM y continúa donde lo dejaste."
                    : "Empieza a gestionar tu CRM de una forma más natural.",
                style: CvText.body,
              ),

              const SizedBox(height: CvSpace.xl + 4),

              if (!isLogin) ...[
                AuthTextField(
                  fieldKey: const ValueKey('auth-name'),
                  label: "Nombre",
                  hint: "Tu nombre",
                  icon: Icons.person_outline,
                  controller: _nombreController,
                  keyboardType: TextInputType.name,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  onChanged: _clearAuthError,
                  validator: (v) =>
                      v == null || v.isEmpty ? "Introduce tu nombre" : null,
                ),
                const SizedBox(height: _fieldGap),
              ],

              AuthTextField(
                fieldKey: const ValueKey('auth-email'),
                label: "Correo electrónico",
                hint: "nombre@empresa.com",
                icon: Icons.mail_outline,
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                onChanged: _clearAuthError,
                validator: (v) {
                  if (v == null || v.isEmpty) return "Introduce tu email";
                  if (!_isValidEmail(v)) return "Email no válido";
                  return null;
                },
              ),

              const SizedBox(height: _fieldGap),

              AuthTextField(
                fieldKey: const ValueKey('auth-password'),
                label: "Contraseña",
                hint: isLogin ? "Tu contraseña" : "Al menos 6 caracteres",
                icon: Icons.lock_outline,
                controller: _passwordController,
                obscure: _obscurePassword,
                textInputAction:
                    isLogin ? TextInputAction.done : TextInputAction.next,
                autofillHints: [
                  isLogin ? AutofillHints.password : AutofillHints.newPassword,
                ],
                onChanged: _clearAuthError,
                onSubmitted: isLogin ? (_) => _submit(formContext) : null,
                suffix: PasswordVisibilityToggle(
                  obscured: _obscurePassword,
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return "Introduce tu contraseña";
                  if (v.length < 6) return "Mínimo 6 caracteres";
                  return null;
                },
              ),

              if (!isLogin) ...[
                const SizedBox(height: _fieldGap),
                AuthTextField(
                  fieldKey: const ValueKey('auth-confirm-password'),
                  label: "Confirmar contraseña",
                  hint: "Repite la contraseña",
                  icon: Icons.lock_outline,
                  controller: _confirmPasswordController,
                  obscure: _obscureConfirmPassword,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.newPassword],
                  onChanged: _clearAuthError,
                  onSubmitted: (_) => _submit(formContext),
                  suffix: PasswordVisibilityToggle(
                    obscured: _obscureConfirmPassword,
                    onPressed: () => setState(() =>
                        _obscureConfirmPassword = !_obscureConfirmPassword),
                  ),
                  validator: (v) {
                    if (v != _passwordController.text) {
                      return "Las contraseñas no coinciden";
                    }
                    return null;
                  },
                ),
              ],

              /// RECUÉRDAME
              if (isLogin) ...[
                const SizedBox(height: CvSpace.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(CvRadius.sm),
                    onTap: () => setState(() => rememberMe = !rememberMe),
                    child: Padding(
                      padding: const EdgeInsets.only(right: CvSpace.xs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: rememberMe,
                            activeColor: CvColors.primaryDark,
                            onChanged: (value) {
                              setState(() {
                                rememberMe = value ?? true;
                              });
                            },
                          ),
                          Text(
                            "Recuérdame",
                            style: CvText.label.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ] else
                const SizedBox(height: CvSpace.xl),

              const SizedBox(height: CvSpace.md),

              if (_authError != null) ...[
                AuthErrorBanner(message: _authError!),
                const SizedBox(height: CvSpace.md),
              ],

              /// CTA
              AuthPrimaryButton(
                label: isLogin ? "Entrar" : "Crear cuenta",
                loading: auth.isLoading,
                onPressed: () => _submit(formContext),
              ),

              /// GOOGLE LOGIN
              /// Web: botón oficial de Google (ID token). Resto: signIn del plugin.
              /// En ambos casos el resultado llega por _onGoogleAccount.
              /// En web sin GOOGLE_CLIENT_ID no se muestra el botón.
              if (!kIsWeb || GoogleAuthService.isConfigured) ...[
                const SizedBox(height: CvSpace.xl),
                const AuthDivider(),
                const SizedBox(height: CvSpace.xl),
                if (kIsWeb)
                  SizedBox(
                    height: 44,
                    child: Center(child: buildGoogleWebButton()),
                  )
                else
                  GoogleAuthButton(
                    key: const ValueKey('auth-google-button'),
                    onPressed: () => GoogleAuthService().signIn(),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
