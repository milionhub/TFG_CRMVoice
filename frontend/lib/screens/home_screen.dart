import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:io';

import '../services/api_service.dart';
import 'history_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- Estado backend ---
  String backendStatus = "Comprobando conexión...";
  String analysisResult = "";
  bool isLoading = false;

  final TextEditingController _textController = TextEditingController(
    text:
        "He estado con el cliente Carlos, quiere presupuesto para el martes.",
  );

  // --- Grabación ---
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  String? _lastAudioRef;

  @override
  void initState() {
    super.initState();
    _checkBackend();
    _requestMicrophonePermissionIfNeeded();
  }

  @override
  void dispose() {
    _recorder.dispose();
    _textController.dispose();
    super.dispose();
  }

  // -----------------------------
  // Permisos
  // -----------------------------
  Future<void> _requestMicrophonePermissionIfNeeded() async {
    if (kIsWeb) return;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      setState(() {
        backendStatus =
            "⚠ Sin permiso de micrófono (actívalo en ajustes del sistema)";
      });
    }
  }

  // -----------------------------
  // Backend ping
  // -----------------------------
  Future<void> _checkBackend() async {
    try {
      final result = await ApiService.ping();
      setState(() {
        backendStatus = "Backend OK: $result";
      });
    } catch (e) {
      setState(() {
        backendStatus = "❌ Error al conectar con backend";
      });
    }
  }

  // -----------------------------
  // Enviar texto
  // -----------------------------
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
            "Fecha: ${data['fecha'] ?? '-'}\n\n"
            "Comentario:\n${data['comentario']}";
      });
    } catch (e) {
      setState(() {
        analysisResult = "❌ Error al procesar el texto.";
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  // -----------------------------
  // Grabar audio
  // -----------------------------
  Future<void> _toggleRecording() async {
    try {
      if (!_isRecording) {
        final hasPermission = await _recorder.hasPermission();
        if (!hasPermission) {
          setState(() {
            analysisResult =
                "No hay permiso de micrófono. Actívalo en el navegador/sistema.";
          });
          return;
        }

        AudioEncoder encoder;
        String ext;

        if (kIsWeb) {
          encoder = AudioEncoder.opus;
          ext = 'opus';
        } else {
          encoder = AudioEncoder.aacLc;
          ext = 'm4a';
        }

        final supported = await _recorder.isEncoderSupported(encoder);
        if (!supported) {
          encoder = AudioEncoder.wav;
          ext = 'wav';
        }

        String? path;
        final fileName =
            'crm_voice_${DateTime.now().millisecondsSinceEpoch}.$ext';

        if (kIsWeb) {
          path = fileName;
        } else {
          final dir = await getTemporaryDirectory();
          path = '${dir.path}/$fileName';
        }

        await _recorder.start(
          RecordConfig(
            encoder: encoder,
            bitRate: 128000,
            sampleRate: 44100,
          ),
          path: path,
        );

        setState(() {
          _isRecording = true;
          _lastAudioRef = null;
        });
      } else {
        final ref = await _recorder.stop();

        setState(() {
          _isRecording = false;
          _lastAudioRef = ref;
        });
      }
    } catch (e) {
      setState(() {
        analysisResult = "❌ Error al manejar grabación: $e";
      });
    }
  }

  // -----------------------------
  // Enviar audio
  // -----------------------------
  Future<void> _sendLastAudioToBackend() async {
    if (_lastAudioRef == null) {
      setState(() {
        analysisResult = "No hay audio para enviar.";
      });
      return;
    }

    setState(() {
      isLoading = true;
      analysisResult = "Procesando audio...";
    });

    try {
      late List<int> bytes;
      late String filename;

      if (kIsWeb) {
        final response = await http.get(Uri.parse(_lastAudioRef!));
        bytes = response.bodyBytes;
        filename = "audio_web.wav";
      } else {
        final file = File(_lastAudioRef!);
        bytes = await file.readAsBytes();
        filename = file.path.split('/').last;
      }

      final data = await ApiService.uploadAudio(
        bytes: bytes,
        filename: filename,
      );

      setState(() {
        analysisResult =
            "Texto detectado:\n${data['texto']}\n\n"
            "Cliente: ${data['cliente_detectado'] ?? '-'}\n"
            "Contacto: ${data['contacto_detectado'] ?? '-'}\n"
            "Acción: ${data['accion_detectada'] ?? '-'}\n"
            "Fecha: ${data['fecha_detectada'] ?? '-'}\n"
            "Estado: ${data['resolution_status'] ?? '-'}";
      });
    } catch (e) {
      setState(() {
        analysisResult = "❌ Error procesando el audio.";
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  // -----------------------------
  // UI
  // -----------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("CRM Voice"),
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HistoryScreen(),
                ),
              );
            },
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              backendStatus,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),

            // GRABACIÓN
            const Text(
              "Grabación de voz",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _toggleRecording,
                  icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                  label: Text(
                      _isRecording ? "Detener grabación" : "Grabar voz"),
                ),
                const SizedBox(width: 16),
                Text(
                  _isRecording ? "🎙 Grabando..." : "⏹️ No grabando",
                  style: TextStyle(
                    color: _isRecording ? Colors.red : Colors.grey,
                  ),
                ),
              ],
            ),

            if (_lastAudioRef != null) ...[
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: isLoading ? null : _sendLastAudioToBackend,
                icon: const Icon(Icons.cloud_upload),
                label: const Text("Enviar audio al backend"),
              ),
            ],

            const Divider(height: 40),

            // TEXTO
            const Text(
              "Texto a analizar",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _textController,
              maxLines: 3,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isLoading ? null : _sendText,
                child: isLoading
                    ? const CircularProgressIndicator()
                    : const Text("Enviar y analizar"),
              ),
            ),

            const SizedBox(height: 20),

            const Text(
              "Resultado",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: SingleChildScrollView(
                child: Text(analysisResult),
              ),
            ),
          ],
        ),
      ),
    );
  }
}