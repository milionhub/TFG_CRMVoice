import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../services/api_service.dart';
import 'package:http/http.dart' as http;
import 'new_activity_screen.dart';
import 'history_screen.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool isConnected = false;
  bool isChecking = true;

  Map<String, dynamic>? analysisResult;
  bool isAnalyzing = false;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    _checkBackend();
  }

  Future<void> _checkBackend() async {
    try {
      final message = await ApiService.ping();

      setState(() {
        isConnected = message == "ok" || message.isNotEmpty;
        isChecking = false;
      });
    } catch (_) {
      setState(() {
        isConnected = false;
        isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),

      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.black87,
        title: const Text(
          "CRM Voice",
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            tooltip: "Histórico",
            icon: const Icon(Icons.menu_book),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HistoryScreen(),
                ),
              );
            },
          ),
          IconButton(
            tooltip: "Chat IA",
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ChatScreen(),
                ),
              );
            },
          ),
        ],
      ),

      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              const SizedBox(height: 8),

              StatusCard(
                isConnected: isConnected,
                isChecking: isChecking,
              ),

              const SizedBox(height: 24),

              Expanded(
                child: Center(
                  child: _RecorderCard(
                    onLoading: () {
                      setState(() {
                        isAnalyzing = true;
                        errorMessage = null;
                      });
                    },
                    onSuccess: (result) {
                      setState(() {
                        isAnalyzing = false;
                        analysisResult = result;
                      });
                    },
                    onError: (msg) {
                      setState(() {
                        isAnalyzing = false;
                        errorMessage = msg;
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}




/// ===============================
/// STATUS CARD
/// ===============================

class StatusCard extends StatelessWidget {
  final bool isConnected;
  final bool isChecking;

  const StatusCard({
    super.key,
    required this.isConnected,
    required this.isChecking,
  });

  @override
  Widget build(BuildContext context) {
    Color iconColor;
    IconData icon;
    String text;

    if (isChecking) {
      iconColor = Colors.orange;
      icon = Icons.sync;
      text = "Comprobando conexión...";
    } else if (isConnected) {
      iconColor = const Color(0xFF1E88E5);
      icon = Icons.cloud_done;
      text = "Backend conectado";
    } else {
      iconColor = Colors.red;
      icon = Icons.cloud_off;
      text = "Backend desconectado";
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 12),
          Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          )
        ],
      ),
    );
  }
}


/// ===============================
/// RECORDER CARD
/// ===============================

class _RecorderCard extends StatefulWidget {
  final Function(Map<String, dynamic>) onSuccess;
  final Function() onLoading;
  final Function(String) onError;

  const _RecorderCard({
    required this.onSuccess,
    required this.onLoading,
    required this.onError,
  });

  @override
  State<_RecorderCard> createState() => _RecorderCardState();
}

class _RecorderCardState extends State<_RecorderCard>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();

  bool isRecording = false;
  bool isLoading = false;

  String? _audioPath;

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
      _audioPath = path;
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
    widget.onLoading();
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

      final result = await ApiService.uploadAudio(
        bytes: bytes,
        filename: path.split('/').last,
      );

     Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NewActivityScreen(result: result),
        ),
      );
    } catch (e) {
        widget.onError("Error enviando audio");
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
    final Color buttonColor =
        isRecording ? Colors.red : const Color(0xFF1E88E5);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 20,
            offset: const Offset(0, 10),
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onLongPressStart: (_) => _startRecording(),
            onLongPressEnd: (_) => _stopRecording(),
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 90,
                width: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: buttonColor,
                ),
                child: isLoading
                    ? const CircularProgressIndicator(
                        color: Colors.white,
                      )
                    : const Icon(
                        Icons.mic,
                        color: Colors.white,
                        size: 42,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            isRecording
                ? "Grabando..."
                : isLoading
                    ? "Procesando audio..."
                    : "Mantén pulsado para grabar",
            style: const TextStyle(
              fontSize: 15,
              color: Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}

