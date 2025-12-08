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
  String backendStatus = "Comprobando conexión...";
  String analysisResult = "";
  bool isLoading = false;

  final TextEditingController _textController = TextEditingController(
    text:
        "He estado con el cliente Carlos, quiere presupuesto para el martes.",
  );

  @override
  void initState() {
    super.initState();
    _checkBackend();
  }

  Future<void> _checkBackend() async {
    try {
      final result = await ApiService.ping();
      setState(() {
        backendStatus = "Backend OK: $result";
      });
    } catch (e) {
      setState(() {
        backendStatus = "Error al conectar con backend";
      });
    }
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        analysisResult = "Introduce un texto para analizar.";
      });
      return;
    }

    setState(() {
      isLoading = true;
      analysisResult = "";
    });

    try {
      final data = await ApiService.analyzeText(text);

      setState(() {
        analysisResult =
            "Cliente: ${data['cliente'] ?? '-'}\n"
            "Acción: ${data['accion'] ?? '-'}\n"
            "Fecha:  ${data['fecha'] ?? '-'}\n\n"
            "Comentario:\n${data['comentario']}";
      });
    } catch (e) {
      setState(() {
        analysisResult = "Error al procesar el texto.";
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("CRM Voice - Análisis de texto"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              backendStatus,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            const Text(
              "Texto a analizar",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _textController,
              maxLines: 3,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: "Escribe aquí lo que diría el comercial...",
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isLoading ? null : _sendText,
                child: isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text("Enviar y analizar"),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "Resultado del análisis",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  analysisResult,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
