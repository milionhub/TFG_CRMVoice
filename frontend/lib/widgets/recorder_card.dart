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

  /// El usuario mantiene pulsado el botón (pulsación larga en curso)
  bool _pressActive = false;

  /// Hay un arranque en curso (petición de permiso y/o start() pendientes)
  bool _starting = false;

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
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Comienzo de la pulsación larga
  void _onPressStart() {
    _pressActive = true;

    // Evita arranques concurrentes o grabar mientras se procesa
    if (_starting || isRecording || isLoading) return;

    _startRecording();
  }

  /// Fin de la pulsación (soltar o cancelar). Idempotente: puede llegar por
  /// onLongPressEnd y por el Listener de puntero para el mismo evento.
  void _onPressEnd() {
    if (!_pressActive) return;
    _pressActive = false;

    // Si aún está arrancando, _startRecording lo detecta al terminar
    if (isRecording) _stopRecording();
  }

  Future<void> _startRecording() async {
    _starting = true;

    try {
      // En web, la primera vez muestra el aviso de permisos del navegador.
      // Para aceptarlo hay que soltar el botón: cuando resuelve, la
      // pulsación ya ha terminado (ver comprobación de _pressActive).
      bool granted;
      try {
        granted = await _recorder.hasPermission();
      } catch (_) {
        granted = false;
      }

      if (!mounted) return;

      if (!granted) {
        _showMessage(
          "Permiso de micrófono denegado. Actívalo en los permisos del sitio "
          "(icono junto a la dirección) y vuelve a intentarlo.",
        );
        return;
      }

      if (!_pressActive) {
        // Permiso recién concedido tras soltar el botón: no grabar ahora
        _showMessage("Micrófono activado. Mantén pulsado para grabar.");
        return;
      }

      String path;

      if (kIsWeb) {
        path = 'audio_${DateTime.now().millisecondsSinceEpoch}.webm';
      } else {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      }

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );

      // En web, record captura internamente los errores de start():
      // confirmamos que la grabación ha empezado de verdad
      final started = await _recorder.isRecording();

      if (!mounted) return;

      if (!started) {
        _showMessage(
          "No se ha podido iniciar la grabación. Inténtalo de nuevo.",
        );
        return;
      }

      if (!_pressActive) {
        // Se soltó mientras start() estaba pendiente: descartar, sin huérfanas
        await _recorder.cancel();
        return;
      }

      setState(() {
        isRecording = true;
      });

      _pulseController.repeat(reverse: true);
    } catch (_) {
      try {
        await _recorder.cancel();
      } catch (_) {}

      if (mounted) {
        _showMessage(
          "No se ha podido iniciar la grabación. Inténtalo de nuevo.",
        );
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopRecording() async {
    if (!isRecording) return;

    _pulseController.stop();
    _pulseController.value = 1.0;

    setState(() {
      isRecording = false;
    });

    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }

    if (!mounted) return;

    if (path == null) {
      _showMessage("No se ha grabado audio. Mantén pulsado mientras hablas.");
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      List<int> bytes;

      if (kIsWeb) {
        final response = await http.get(Uri.parse(path));
        bytes = response.bodyBytes;
      } else {
        final file = File(path);
        bytes = await file.readAsBytes();
      }

      if (!mounted) return;

      final api = context.read<ApiService>();
      final result = await api.uploadAudio(
        bytes: bytes,
        filename: path.split('/').last,
      );

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => NewActivityScreen(result: result)),
      );
    } catch (_) {
      if (mounted) _showMessage("Error enviando audio");
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
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
            // Listener: los eventos de puntero llegan siempre, aunque el
            // reconocedor de pulsación larga no notifique una cancelación
            // posterior a onLongPressStart.
            child: Listener(
              onPointerUp: (_) => _onPressEnd(),
              onPointerCancel: (_) => _onPressEnd(),
              child: GestureDetector(
                onLongPressStart: (_) => _onPressStart(),
                onLongPressEnd: (_) => _onPressEnd(),
                onLongPressCancel: _onPressEnd,
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
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Icon(
                            Icons.mic_rounded,
                            color: Colors.white,
                            size: 42,
                          ),
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
            style: TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
