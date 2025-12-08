import 'package:flutter/material.dart';

void main() {
  runApp(const CRMVoiceApp());
}

class CRMVoiceApp extends StatelessWidget {
  const CRMVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CRM Voice',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('CRM Voice - Sprint 1'),
        ),
        body: const Center(
          child: Text(
            'Hola, bienvenido a CRM Voice 👋\n'
            'Aquí comenzará tu TFG.\n\n'
            'Frontend Flutter funcionando correctamente ✅',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18),
          ),
        ),
      ),
    );
  }
}
