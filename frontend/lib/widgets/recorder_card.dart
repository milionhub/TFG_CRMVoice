import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../screens/new_activity_screen.dart';
import '../core/app_colors.dart';

class RecorderCard extends StatefulWidget {
  const RecorderCard({super.key});

  @override
  State<RecorderCard> createState() => _RecorderCardState();
}

class _RecorderCardState extends State<RecorderCard>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();

  bool isRecording = false;
  bool isLoading = false;

  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );
  }

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return;

    String path;

    if (kIsWeb) {
      path = 'audio_${DateTime.now().millisecondsSinceEpoch}.webm';
    } else {
      final dir = await getTemporaryDirectory();
      path =
          '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
    }

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: path,
    );

    setState(() {
      isRecording = true;
    });

    _pulseController.repeat(reverse: true);
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();

    _pulseController.stop();
    _pulseController.value = 1.0;

    setState(() {
      isRecording = false;
      isLoading = true;
    });

    if (path == null) return;

    try {
      List<int> bytes;

      if (kIsWeb) {
        final response = await http.get(Uri.parse(path));
        bytes = response.bodyBytes;
      } else {
        final file = File(path);
        bytes = await file.readAsBytes();
      }

      final api = context.read<ApiService>();
      final result = await api.uploadAudio(
        bytes: bytes,
        filename: path.split('/').last,
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NewActivityScreen(result: result),
        ),
      );
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Error enviando audio")),
      );
    }

    setState(() {
      isLoading = false;
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _recorder.dispose();
    super.dispose();
  }

 @override
Widget build(BuildContext context) {
  final Color primary = AppColors.primary;

  return Container(
    width: 520,
    padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 40),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(28),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 40,
          offset: const Offset(0, 20),
        ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: primary.withOpacity(0.08),
          ),
          child: GestureDetector(
            onLongPressStart: (_) => _startRecording(),
            onLongPressEnd: (_) => _stopRecording(),
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 100,
                width: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: isRecording
                        ? [Colors.red.shade400, Colors.red.shade600]
                        : [primary, primary.withOpacity(0.85)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isRecording
                          ? Colors.red.withOpacity(0.4)
                          : primary.withOpacity(0.4),
                      blurRadius: 25,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: isLoading
                    ? const CircularProgressIndicator(
                        color: Colors.white,
                      )
                    : const Icon(
                        Icons.mic_rounded,
                        color: Colors.white,
                        size: 42,
                      ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 32),

        Text(
          isRecording
              ? "Grabando..."
              : isLoading
                  ? "Procesando audio..."
                  : "Mantén pulsado para grabar",
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: isRecording ? Colors.red : Colors.black87,
          ),
        ),

        const SizedBox(height: 8),

        const Text(
          "Tu asistente convertirá tu voz en actividad automáticamente",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: Colors.black54,
          ),
        ),
      ],
    ),
  );
}
}