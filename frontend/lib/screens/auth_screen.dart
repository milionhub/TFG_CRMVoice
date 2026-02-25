import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  bool isLogin = true;
  bool rememberMe = true;

  final _formKey = GlobalKey<FormState>();
  final _nombreController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnimation =
        CurvedAnimation(parent: _animationController, curve: Curves.easeInOut);

    _animationController.forward();
  }

  @override
  void dispose() {
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

  void _toggleMode() {
    _animationController.reverse().then((_) {
      setState(() {
        isLogin = !isLogin;
        _formKey.currentState?.reset();
        _nombreController.clear();
        _emailController.clear();
        _passwordController.clear();
        _confirmPasswordController.clear();
      });
      _animationController.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth > 900;

          if (!isDesktop) {
            return _buildMobileLayout(context, auth);
          }

          return Row(
            children: [
              /// LEFT — BRANDING
              Expanded(
                child: Container(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 80),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.mic_rounded,
                          size: 72,
                          color: Color(0xFF1565C0),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          "CRM Voice",
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          "Gestión inteligente de actividades\nimpulsada por voz e IA.",
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.black54,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 40),
                        _featureItem(Icons.security, "Autenticación segura"),
                        _featureItem(Icons.flash_on, "Procesamiento inteligente"),
                        _featureItem(Icons.analytics, "Histórico organizado"),
                      ],
                    ),
                  ),
                ),
              ),

              /// RIGHT — FORM PANEL
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color(0xFF1565C0),
                        Color(0xFF1E88E5),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Center(
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: Container(
                        width: 420,
                        padding: const EdgeInsets.all(40),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.15),
                              blurRadius: 40,
                              offset: const Offset(0, 20),
                            )
                          ],
                        ),
                        child: _buildForm(context, auth),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context, AuthProvider auth) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFF1565C0),
            Color(0xFF1E88E5),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  )
                ],
              ),
              child: _buildForm(context, auth),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, AuthProvider auth) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isLogin ? "Iniciar sesión" : "Crear cuenta",
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),

          if (!isLogin)
            _inputField(
              controller: _nombreController,
              label: "Nombre",
              validator: (v) =>
                  v == null || v.isEmpty ? "Introduce tu nombre" : null,
            ),

          _inputField(
            controller: _emailController,
            label: "Email",
            validator: (v) {
              if (v == null || v.isEmpty) return "Introduce tu email";
              if (!_isValidEmail(v)) return "Email no válido";
              return null;
            },
          ),

          _inputField(
            controller: _passwordController,
            label: "Password",
            obscure: true,
            validator: (v) {
              if (v == null || v.isEmpty) return "Introduce tu contraseña";
              if (v.length < 6) return "Mínimo 6 caracteres";
              return null;
            },
          ),
          if (isLogin)
            Row(
              children: [
                Checkbox(
                  value: rememberMe,
                  activeColor: const Color(0xFF1565C0),
                  onChanged: (value) {
                    setState(() {
                      rememberMe = value ?? true;
                    });
                  },
                ),
                const Text("Recuérdame"),
              ],
            ),
          if (!isLogin)
            _inputField(
              controller: _confirmPasswordController,
              label: "Confirmar password",
              obscure: true,
              validator: (v) {
                if (v != _passwordController.text) {
                  return "Las contraseñas no coinciden";
                }
                return null;
              },
            ),

          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: auth.isLoading
                  ? null
                  : () async {
                      FocusScope.of(context).unfocus();
                      if (!_formKey.currentState!.validate()) return;

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

                      if (!success) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Credenciales incorrectas"),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
              child: auth.isLoading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : Text(
                      isLogin ? "Entrar" : "Registrarse",
                      style: const TextStyle(fontSize: 16),
                    ),
            ),
          ),

          const SizedBox(height: 16),

          TextButton(
            onPressed: auth.isLoading ? null : _toggleMode,
            child: Text(
              isLogin
                  ? "¿No tienes cuenta? Regístrate"
                  : "¿Ya tienes cuenta? Inicia sesión",
            ),
          )
        ],
      ),
    );
  }

  Widget _inputField({
    required TextEditingController controller,
    required String label,
    bool obscure = false,
    required String? Function(String?) validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        validator: validator,
      ),
    );
  }

  Widget _featureItem(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF1565C0)),
          const SizedBox(width: 12),
          Text(
            text,
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
    );
  }
}