// Entrada de voz de Home (H.4, Voice V2).
//
// micrófono -> POST /actions/interpret-audio (Whisper + Action Engine)
//           -> borrador del servidor -> revisión -> confirmación explícita.
// Nada se guarda en el CRM sin confirmar. También se puede escribir la acción
// (POST /actions/interpret), útil si no hay micrófono o Whisper se equivoca.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/app_colors.dart';
import '../models/action_draft.dart';
import '../screens/client_detail_screen.dart';
import '../screens/history_screen.dart';
import '../services/api_service.dart';
import 'crm/crm_ui.dart';
import 'voice/draft_review.dart';

enum VoiceState { idle, requestingPermission, recording, uploading, error }

class RecorderCard extends StatefulWidget {
  /// Una grabación más larga se para sola (el backend admite hasta 10 MB).
  static const maxRecording = Duration(minutes: 2);

  const RecorderCard({super.key});

  @override
  State<RecorderCard> createState() => _RecorderCardState();
}

class _RecorderCardState extends State<RecorderCard> {
  final AudioRecorder _recorder = AudioRecorder();

  VoiceState _state = VoiceState.idle;
  String? _error;

  /// Transcripción que devolvió el servidor junto a un error (se conserva
  /// para corregirla y escribirla en vez de volver a dictar).
  String? _errorTranscript;

  /// Último audio enviado, para reintentar sin volver a grabar.
  ({List<int> bytes, String filename})? _lastAudio;
  bool _canRetryUpload = false;

  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  void _fail(String message, {String? transcript, bool canRetryUpload = false}) {
    if (!mounted) return;
    setState(() {
      _state = VoiceState.error;
      _error = message;
      _errorTranscript = transcript;
      _canRetryUpload = canRetryUpload && _lastAudio != null;
    });
  }

  // ------------------------------------------------------------------
  // Grabación
  // ------------------------------------------------------------------

  Future<void> _start() async {
    if (_state != VoiceState.idle && _state != VoiceState.error) return; // nada concurrente
    setState(() {
      _state = VoiceState.requestingPermission;
      _error = null;
      _errorTranscript = null;
    });

    bool granted;
    try {
      granted = await _recorder.hasPermission();
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    if (!granted) {
      _fail('Permiso de micrófono denegado. Actívalo en los permisos del navegador o del sistema '
          'y vuelve a intentarlo, o escribe la acción.');
      return;
    }

    try {
      final String path;
      if (kIsWeb) {
        path = 'audio_${DateTime.now().millisecondsSinceEpoch}.webm';
      } else {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      }
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
        path: path,
      );
      // En web, record captura los errores de start(): se comprueba que graba
      final started = await _recorder.isRecording();
      if (!mounted) return;
      if (!started) {
        _fail('No se ha podido iniciar la grabación. Inténtalo de nuevo.');
        return;
      }
    } catch (_) {
      try {
        await _recorder.cancel();
      } catch (_) {}
      _fail('No se ha podido iniciar la grabación. Inténtalo de nuevo.');
      return;
    }

    setState(() {
      _state = VoiceState.recording;
      _elapsed = Duration.zero;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed += const Duration(seconds: 1));
      if (_elapsed >= RecorderCard.maxRecording) _stop();
    });
  }

  Future<void> _cancelRecording() async {
    if (_state != VoiceState.recording) return;
    _ticker?.cancel();
    try {
      await _recorder.cancel();
    } catch (_) {}
    if (mounted) setState(() => _state = VoiceState.idle);
  }

  Future<void> _stop() async {
    if (_state != VoiceState.recording) return; // un solo stop/subida por grabación
    _ticker?.cancel();
    setState(() => _state = VoiceState.uploading);

    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    if (path == null) {
      _fail('No se ha grabado audio. Pulsa el micrófono, habla y vuelve a pulsar para terminar.');
      return;
    }

    List<int> bytes;
    try {
      if (kIsWeb) {
        bytes = (await http.get(Uri.parse(path))).bodyBytes;
      } else {
        bytes = await File(path).readAsBytes();
      }
    } catch (_) {
      _fail('No se ha podido leer la grabación. Inténtalo de nuevo.');
      return;
    }
    if (bytes.isEmpty) {
      _fail('La grabación está vacía. Inténtalo de nuevo.');
      return;
    }
    if (bytes.length > ApiService.maxAudioBytes) {
      _fail('La grabación es demasiado larga (máximo 10 MB). Graba un mensaje más corto.');
      return;
    }
    _lastAudio = (bytes: bytes, filename: path.split('/').last.split('\\').last);
    await _upload();
  }

  // ------------------------------------------------------------------
  // Interpretación y revisión
  // ------------------------------------------------------------------

  Future<void> _upload() async {
    final audio = _lastAudio;
    if (audio == null) return;
    setState(() {
      _state = VoiceState.uploading;
      _error = null;
    });
    try {
      final result =
          await context.read<ApiService>().interpretAudio(bytes: audio.bytes, filename: audio.filename);
      if (!mounted) return;
      setState(() {
        _state = VoiceState.idle;
        _lastAudio = null;
      });
      await _review(result.draft);
    } on ApiException catch (e) {
      final transcript = e.body['transcript'];
      final detail = e.body['detail'];
      _fail(
        detail is String ? detail : e.message,
        transcript: transcript is String && transcript.trim().isNotEmpty ? transcript : null,
        // Red, servicio no disponible o error del servidor: se puede reenviar el mismo audio
        canRetryUpload: e.kind == ApiErrorKind.network ||
            e.kind == ApiErrorKind.unavailable ||
            e.kind == ApiErrorKind.server,
      );
    }
  }

  Future<void> _writeAction() async {
    if (_state == VoiceState.recording || _state == VoiceState.uploading || _state == VoiceState.requestingPermission) {
      return;
    }
    final draft = await showDialog<ActionDraft>(
      context: context,
      builder: (_) => CrmTheme(child: _TextActionDialog(initialText: _errorTranscript)),
    );
    if (draft == null || !mounted) return;
    setState(() {
      _state = VoiceState.idle;
      _error = null;
      _errorTranscript = null;
      _lastAudio = null;
    });
    await _review(draft);
  }

  Future<void> _review(ActionDraft draft) async {
    final outcome = await openDraftReview(context, draft: draft);
    if (outcome == null || !mounted) return;
    final clientId = outcome.result.clientId;
    switch (outcome.target) {
      case VoiceNavTarget.clientDetail when clientId != null:
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ClientDetailScreen(clientId: clientId)));
      case VoiceNavTarget.history:
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()));
      default:
        break;
    }
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  void _onMicPressed() {
    switch (_state) {
      case VoiceState.idle:
      case VoiceState.error:
        _start();
      case VoiceState.recording:
        _stop();
      case VoiceState.requestingPermission:
      case VoiceState.uploading:
        break; // en curso: sin dobles grabaciones ni dobles subidas
    }
  }

  String get _statusText => switch (_state) {
        VoiceState.idle => 'Pulsa para hablar',
        VoiceState.requestingPermission => 'Pidiendo permiso del micrófono...',
        VoiceState.recording =>
          'Grabando ${_elapsed.inMinutes}:${two(_elapsed.inSeconds % 60)} · pulsa para terminar',
        VoiceState.uploading => 'Transcribiendo e interpretando...',
        VoiceState.error => 'No se ha podido completar',
      };

  @override
  Widget build(BuildContext context) {
    const primary = AppColors.primary;
    final recording = _state == VoiceState.recording;
    final busy = _state == VoiceState.uploading || _state == VoiceState.requestingPermission;
    final color = recording ? Colors.red.shade600 : primary;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 40, offset: const Offset(0, 20)),
          ],
        ),
        child: CrmTheme(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: recording ? 'Terminar grabación' : 'Hablar: grabar una acción por voz',
                child: Tooltip(
                  message: recording ? 'Terminar grabación' : 'Grabar una acción por voz',
                  child: Material(
                    key: const Key('voice-mic'),
                    color: color,
                    shape: const CircleBorder(),
                    elevation: recording ? 8 : 3,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: busy ? null : _onMicPressed,
                      child: SizedBox(
                        width: 100,
                        height: 100,
                        child: Center(
                          child: busy
                              ? const SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                              : Icon(recording ? Icons.stop_rounded : Icons.mic_rounded, color: Colors.white, size: 44),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _statusText,
                key: const Key('voice-status'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: recording ? Colors.red.shade700 : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              if (_state == VoiceState.error && _error != null) ...[
                FormErrorBanner(message: _error!),
                if (_errorTranscript != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('Se ha entendido: «$_errorTranscript»',
                        textAlign: TextAlign.center, style: const TextStyle(fontStyle: FontStyle.italic)),
                  ),
              ] else
                const Text(
                  'Di qué quieres registrar: una actividad, un cliente, un contacto o una venta. '
                  'Revisarás todo antes de guardar.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (recording)
                    TextButton.icon(
                      onPressed: _cancelRecording,
                      icon: const Icon(Icons.close),
                      label: const Text('Cancelar grabación'),
                    ),
                  if (_state == VoiceState.error && _canRetryUpload)
                    FilledButton.icon(
                      onPressed: _upload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar envío'),
                    ),
                  if (!recording && !busy)
                    OutlinedButton.icon(
                      onPressed: _writeAction,
                      icon: const Icon(Icons.keyboard_outlined),
                      label: Text(_errorTranscript != null ? 'Corregir el texto' : 'Escribir la acción'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Acción escrita (o transcripción corregida) -> POST /actions/interpret.
class _TextActionDialog extends StatefulWidget {
  final String? initialText;

  const _TextActionDialog({this.initialText});

  @override
  State<_TextActionDialog> createState() => _TextActionDialogState();
}

class _TextActionDialogState extends State<_TextActionDialog> {
  late final _text = TextEditingController(text: widget.initialText);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    if (_busy) return;
    if (text.isEmpty) {
      setState(() => _error = 'Escribe qué quieres hacer.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = await context.read<ApiService>().interpretText(text);
      if (mounted) Navigator.pop(context, draft);
    } on ApiException catch (e) {
      // El texto se conserva para corregirlo
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Escribir la acción'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) FormErrorBanner(message: _error!),
            TextField(
              key: const Key('voice-text-field'),
              controller: _text,
              autofocus: true,
              enabled: !_busy,
              minLines: 2,
              maxLines: 5,
              maxLength: 2000,
              decoration: const InputDecoration(
                hintText: 'Ej.: Mañana a las diez llamar a Ana de Rivera por el portátil Luna 13',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_fix_high),
          label: Text(_busy ? 'Interpretando...' : 'Interpretar'),
        ),
      ],
    );
  }
}
