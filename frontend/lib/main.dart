import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/activity_provider.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ActivityProvider()),
      ],
      child: const CRMVoiceApp(),
    ),
  );
}

class CRMVoiceApp extends StatelessWidget {
  const CRMVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "CRM Voice",
      theme: ThemeData.dark(),
      home: const HomeScreen(),
    );
  }
}