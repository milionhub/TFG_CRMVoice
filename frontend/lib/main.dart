import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'services/api_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cross_file/cross_file.dart';


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
  // --- Estado backend / análisis de texto ---
  String backendStatus = "Comprobando conexión...";
  String analysisResult = "";
  bool isLoading = false;

  final TextEditingController _textController = TextEditingController(
    text:
        "He estado con el cliente Carlos, quiere presupuesto para el martes.",
  );

  // --- Grabación de audio ---
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  String? _lastAudioRef; // ruta (nativo) o URL interna (web)

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

  // ---- Permisos micrófono (no necesarios en web, allí pregunta el navegador) ----
  Future<void> _requestMicrophonePermissionIfNeeded() async {
    if (kIsWeb) return; // en web, el permiso lo gestiona el navegador

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      setState(() {
        backendStatus =
            "Atención: sin permiso de micrófono (puedes activarlo en ajustes del sistema).";
      });
    }
  }

  // ---- Comprobación backend ----
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

  // ---- Envío de texto al backend ----
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

Future<void> _toggleRecording() async {
  try {
    if (!_isRecording) {
      // ---------- EMPEZAR A GRABAR ----------
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        setState(() {
          analysisResult =
              "No hay permiso de micrófono. Actívalo en el navegador/sistema.";
        });
        return;
      }

      // Elegimos encoder + extensión según plataforma
      AudioEncoder encoder;
      String ext;

      if (kIsWeb) {
        // En web usamos OPUS (OGG) -> compatible con navegadores
        encoder = AudioEncoder.opus;
        ext = 'opus';
      } else {
        // En móvil/escritorio usamos AAC LC en contenedor m4a
        encoder = AudioEncoder.aacLc;
        ext = 'm4a';
      }

      // Por si acaso el encoder elegido no está soportado, hacemos fallback a WAV
      final supported = await _recorder.isEncoderSupported(encoder);
      if (!supported) {
        encoder = AudioEncoder.wav;
        ext = 'wav';
      }

      // Construimos ruta / identificador
      String? path;
      final fileName =
          'crm_voice_${DateTime.now().millisecondsSinceEpoch}.$ext';

      if (kIsWeb) {
        // En web es solo un identificador/nombre lógico
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
      // ---------- DETENER GRABACIÓN ----------
      final ref = await _recorder.stop();

      setState(() {
        _isRecording = false;
        _lastAudioRef = ref; // ruta (nativo) o URL/blob (web)
      });
    }
  } catch (e) {
    setState(() {
      analysisResult = "Error al manejar la grabación: $e";
    });
  }
}

Future<void> _sendLastAudioToBackend() async {
  if (_lastAudioRef == null) {
    setState(() {
      analysisResult = "No hay ninguna grabación para enviar.";
    });
    return;
  }

  setState(() {
    isLoading = true;
    analysisResult = "";
  });

  try {
    // XFile distinto en web / nativo
    final xfile = XFile(_lastAudioRef!);
    final bytes = await xfile.readAsBytes();


    // nombre de archivo “bonito”
    final filename = _lastAudioRef!.split('/').last;

    final resp = await ApiService.uploadAudio(
      bytes: bytes,
      filename: filename,
    );

    setState(() {
      analysisResult =
          "Audio enviado correctamente.\n\n"
          "Archivo: ${resp['filename']}\n"
          "Tipo: ${resp['content_type']}\n"
          "Tamaño: ${resp['size_kb']} KB\n"
          "Mensaje backend: ${resp['detail']}";
    });
  } catch (e) {
    setState(() {
      analysisResult = "Error al enviar audio: $e";
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
            // Estado del backend
            Text(
              backendStatus,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // --- SECCIÓN: GRABACIÓN DE VOZ ---
            const Text(
              "Grabación de voz",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _toggleRecording,
                  icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                  label: Text(
                    _isRecording ? "Detener grabación" : "Grabar voz",
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  _isRecording ? "🎙 Grabando..." : "⏹️ No grabando",
                  style: TextStyle(
                    fontSize: 14,
                    color: _isRecording ? Colors.red : Colors.grey[700],
                  ),
                ),
              ],
            ),
            if (_lastAudioRef != null) ...[
              const SizedBox(height: 8),
              const Text(
                "Último audio capturado (listo para enviar al backend):",
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              Text(
                _lastAudioRef!,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: isLoading ? null : _sendLastAudioToBackend,
                icon: const Icon(Icons.cloud_upload),
                label: const Text("Enviar audio al backend"),
              ),
            ],

            const Divider(height: 32),

            // --- SECCIÓN: ANÁLISIS DE TEXTO ---
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
