import 'package:flutter/material.dart';
import 'services/api_service.dart';

void main() {
  runApp(const CRMVoiceApp());
}

class CRMVoiceApp extends StatelessWidget {
  const CRMVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String status = "No conectado";

  void conectarBackend() async {
    try {
      final result = await ApiService.ping();
      setState(() {
        status = result;
      });
    } catch (e) {
      setState(() {
        status = "Error de conexión";
      });
    }
  }

  @override
  void initState() {
    super.initState();
    conectarBackend();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("CRM Voice")),
      body: Center(
        child: Text(
          status,
          style: const TextStyle(fontSize: 22),
        ),
      ),
    );
  }
}
