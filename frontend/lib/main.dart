import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/activity_provider.dart';
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

        ProxyProvider<ApiService, ActivityProvider>(
          update: (_, api, __) => ActivityProvider(api),
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
      debugShowCheckedModeBanner: false,
      title: "CRM Voice",
      theme: ThemeData.dark(),

      home: auth.isAuthenticated
    ? const HomeScreen()
    : const AuthScreen()
    );
  }
}