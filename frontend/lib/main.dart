import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/navigation.dart';
import 'providers/auth_provider.dart';
import 'screens/home_screen.dart';
import 'screens/auth_screen.dart';
import 'services/api_service.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [

        ChangeNotifierProvider(create: (_) => AuthProvider()),

        ProxyProvider<AuthProvider, ApiService>(
          update: (_, auth, __) => ApiService(auth),
        ),
      ],
      child: const CRMVoiceApp(),
    ),
  );
}

class CRMVoiceApp extends StatefulWidget {
  const CRMVoiceApp({super.key});

  @override
  State<CRMVoiceApp> createState() => _CRMVoiceAppState();
}

class _CRMVoiceAppState extends State<CRMVoiceApp> {
  @override
  void initState() {
    super.initState();

    // Inicializar sesión guardada
    Future.microtask(() {
      Provider.of<AuthProvider>(context, listen: false).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);

    return MaterialApp(
      // Al entrar/salir de sesión se recrea el Navigator: no quedan
      // pantallas anteriores (Histórico, Calendario...) encima de AuthScreen
      key: ValueKey(auth.isAuthenticated),
      debugShowCheckedModeBanner: false,
      title: "CRMVoice",
      theme: ThemeData.dark(),
      // Recarga de las métricas de Home al volver a ella (H.5.2)
      navigatorObservers: [crmRouteObserver],

      home: !auth.isInitialized
        ? const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          )
        : auth.isAuthenticated
            ? const HomeScreen()
            : const AuthScreen(),
    );
  }
}