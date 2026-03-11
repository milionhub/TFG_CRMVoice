import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/app_logo.dart';
import '../core/app_colors.dart';
import '../services/google_auth_service.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {

  bool isLogin = true;
  bool rememberMe = true;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

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

    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );

    _animationController.forward();

    /// AUTO LOGIN GOOGLE
    WidgetsBinding.instance.addPostFrameCallback((_) async {

      final auth = context.read<AuthProvider>();

      await auth.tryGoogleAutoLogin();

    });
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

  void _switchMode(bool login) {
    _animationController.reverse().then((_) {
      setState(() {
        isLogin = login;
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

      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),

            child: Padding(
              padding: const EdgeInsets.all(24),

              child: Container(
                padding: const EdgeInsets.all(36),

                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),

                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),

                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [

                    const AppLogo(size: 140),

                    const SizedBox(height: 24),

                    /// LOGIN / SIGNUP SWITCH
                    Row(
                      children: [

                        Expanded(
                          child: _authTab(
                            title: "Login",
                            selected: isLogin,
                            onTap: () => _switchMode(true),
                          ),
                        ),

                        Expanded(
                          child: _authTab(
                            title: "Sign Up",
                            selected: !isLogin,
                            onTap: () => _switchMode(false),
                          ),
                        ),

                      ],
                    ),

                    const SizedBox(height: 30),

                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0.05, 0),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                      child: _buildForm(auth),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(AuthProvider auth) {

    return Form(
      key: _formKey,

      child: Column(
        key: ValueKey(isLogin),
        mainAxisSize: MainAxisSize.min,

        children: [

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
            obscure: _obscurePassword,
            validator: (v) {
              if (v == null || v.isEmpty) return "Introduce tu contraseña";
              if (v.length < 6) return "Mínimo 6 caracteres";
              return null;
            },
          ),

          if (!isLogin)
            _inputField(
              controller: _confirmPasswordController,
              label: "Confirmar password",
              obscure: _obscureConfirmPassword,
              validator: (v) {
                if (v != _passwordController.text) {
                  return "Las contraseñas no coinciden";
                }
                return null;
              },
            ),

          if (isLogin)
            Row(
              children: [
                Checkbox(
                  value: rememberMe,
                  activeColor: AppColors.primary,
                  onChanged: (value) {
                    setState(() {
                      rememberMe = value ?? true;
                    });
                  },
                ),
                const Text(
                  "Recuérdame",
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),

          const SizedBox(height: 24),

          /// LOGIN BUTTON
          SizedBox(
            width: double.infinity,

            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
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
                      isLogin ? "Entrar" : "Crear cuenta",
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                 ),
          ),

          const SizedBox(height: 20),

          /// GOOGLE LOGIN
          /// GOOGLE LOGIN
          GestureDetector(
            onTap: () async {

              final googleAuth = GoogleAuthService();

              final result = await googleAuth.signIn();

              if (result == null) return;

              final accessToken = result["accessToken"];

              final success =
                  await context.read<AuthProvider>().googleLogin(accessToken);

              if (!success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Error con Google Login"),
                  ),
                );
              }

            },

            child: Container(
              width: double.infinity,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.white,
              ),
              alignment: Alignment.center,
              child: SvgPicture.asset(
                "assets/images/google-logo.svg",
                height: 78, // 👈 más grande para que se vea bien
              ),
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

          /// 👁 ICONO MOSTRAR / OCULTAR PASSWORD
          suffixIcon: label == "Password"
              ? IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: Colors.grey,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscurePassword = !_obscurePassword;
                    });
                  },
                )
              : label == "Confirmar password"
                  ? IconButton(
                      icon: Icon(
                        _obscureConfirmPassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: Colors.grey,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureConfirmPassword =
                              !_obscureConfirmPassword;
                        });
                      },
                    )
                  : null,

          filled: true,
          fillColor: const Color(0xFFF4F6F8),

          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),

        validator: validator,
      ),
    );
  }

  Widget _authTab({
    required String title,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),

        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withOpacity(0.08)
              : Colors.transparent,

          borderRadius: BorderRadius.circular(10),

          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withOpacity(0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  )
                ]
              : [],
        ),

        child: Center(
          child: Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: selected
                  ? AppColors.primary
                  : Colors.black54,
            ),
          ),
        ),
      ),
    );
  }
}