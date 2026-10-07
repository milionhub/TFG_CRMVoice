// Entrada de voz de Home (H.4, Voice V2).
//
// micrófono -> POST /actions/interpret-audio (Whisper + Action Engine)
//           -> borrador del servidor -> revisión -> confirmación explícita.
// Nada se guarda en el CRM sin confirmar. También se puede escribir la acción
// (POST /actions/interpret), útil si no hay micrófono o Whisper se equivoca.
// I.2: presentación como «Voice Hero» del Inicio (solo UI; la lógica no cambia).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/design/cv_theme.dart';
import '../core/design/cv_tokens.dart';
import '../models/action_draft.dart';
import '../screens/client_detail_screen.dart';
import '../screens/history_screen.dart';
import '../services/api_service.dart';
import 'brand/crm_voice_brand.dart';
import 'chat/chat_identity.dart' show AssistantMark;
import 'crm/crm_ui.dart';
import 'crm/form_shell.dart';
import 'ui/cv_components.dart';
import 'ui/cv_feedback.dart';
import 'shell/app_shell.dart';
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
    final draft = await openCrmForm<ActionDraft>(context, _TextActionDialog(initialText: _errorTranscript));
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
        // Ruta del shell (la barra lateral no se anima; I.3.2)
        await Navigator.push(context, SectionRoute(builder: (_) => ClientDetailScreen(clientId: clientId)));
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
    final recording = _state == VoiceState.recording;
    final busy = _state == VoiceState.uploading || _state == VoiceState.requestingPermission;
    final failed = _state == VoiceState.error;

    final (Color statusColor, Color dotColor) = switch (_state) {
      VoiceState.recording => (CvColors.danger, CvColors.danger),
      VoiceState.error => (CvColors.danger, CvColors.danger),
      VoiceState.uploading || VoiceState.requestingPermission => (CvColors.primaryDark, CvColors.primary),
      VoiceState.idle => (CvColors.textSecondary, CvColors.primary),
    };

    final mic = _MicButton(
      recording: recording,
      busy: busy,
      pulse: _elapsed.inSeconds,
      onPressed: _onMicPressed,
    );

    Widget texts(bool center) => Column(
          crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CrmVoiceMark(size: 16, plain: true, color: CvColors.primaryDark),
                const SizedBox(width: CvSpace.xs - 2),
                Flexible(
                  child: Text(
                    'Habla con tu CRM',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CvText.label.copyWith(fontSize: 12.5, color: CvColors.primaryDark),
                  ),
                ),
              ],
            ),
            const SizedBox(height: CvSpace.xs - 2),
            Semantics(
              header: true,
              child: Text(
                '¿Qué quieres registrar?',
                textAlign: center ? TextAlign.center : TextAlign.start,
                style: CvText.heading.copyWith(fontSize: 21, letterSpacing: -0.4),
              ),
            ),
            const SizedBox(height: CvSpace.xxs),
            Text(
              'Dicta una actividad, un cliente, un contacto o una venta. Revisarás todo antes de guardar.',
              textAlign: center ? TextAlign.center : TextAlign.start,
              style: CvText.body.copyWith(fontSize: 14),
            ),
            const SizedBox(height: CvSpace.sm),
            Semantics(
              liveRegion: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: CvSpace.xs),
                  Flexible(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: CvText.label.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: statusColor,
                      ),
                      child: Text(_statusText, key: const Key('voice-status')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

    final actions = Wrap(
      alignment: WrapAlignment.center,
      spacing: CvSpace.xs,
      runSpacing: CvSpace.xs,
      children: [
        if (recording)
          TextButton.icon(
            onPressed: _cancelRecording,
            style: TextButton.styleFrom(
              foregroundColor: CvColors.textSecondary,
              minimumSize: const Size(0, 44),
            ),
            icon: const Icon(Icons.close, size: 18),
            label: const Text('Cancelar grabación'),
          ),
        if (failed && _canRetryUpload)
          CvPrimaryButton(label: 'Reintentar envío', icon: Icons.refresh_rounded, onPressed: _upload),
        if (!recording && !busy)
          CvSecondaryButton(
            label: _errorTranscript != null ? 'Corregir el texto' : 'Escribir la acción',
            icon: Icons.keyboard_outlined,
            onPressed: _writeAction,
          ),
      ],
    );

    final errorDetails = failed && _error != null
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: CvSpace.md),
              CvInlineAlert(message: _error!),
              const SizedBox(height: CvSpace.xs),
              if (_errorTranscript != null)
                Text('Se ha entendido: «$_errorTranscript»',
                    textAlign: TextAlign.center,
                    style: CvText.body.copyWith(fontSize: 13.5, fontStyle: FontStyle.italic)),
            ],
          )
        : null;

    return CrmTheme(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 800;
          return AnimatedContainer(
            key: const Key('voice-hero'),
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: CvColors.surface,
              borderRadius: BorderRadius.circular(CvRadius.card),
              border: Border.all(
                color: recording ? CvColors.danger.withValues(alpha: 0.35) : CvColors.border,
              ),
              boxShadow: CvShadows.panel,
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                // Señal CRMVoice muy tenue a la derecha (estática)
                if (wide)
                  const Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: 360,
                    child: ExcludeSemantics(child: CustomPaint(painter: _HeroWavePainter())),
                  ),
                Padding(
                  padding: EdgeInsets.all(wide ? 28 : CvSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide)
                        Row(
                          children: [
                            mic,
                            const SizedBox(width: CvSpace.xl),
                            Expanded(child: texts(false)),
                            const SizedBox(width: CvSpace.xl),
                            actions,
                          ],
                        )
                      else ...[
                        Center(child: mic),
                        const SizedBox(height: CvSpace.md),
                        texts(true),
                        const SizedBox(height: CvSpace.md),
                        actions,
                      ],
                      ?errorDetails,
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Botón del micrófono: sólido primaryDark (rojo mientras graba) sobre un
/// halo suave. Mientras graba, una onda corta (650 ms) se expande una vez
/// por segundo ([pulse] cambia con el contador) y se detiene entre pulsos;
/// sin animación permanente en reposo.
class _MicButton extends StatefulWidget {
  final bool recording;
  final bool busy;
  final int pulse;
  final VoidCallback onPressed;

  const _MicButton({
    required this.recording,
    required this.busy,
    required this.pulse,
    required this.onPressed,
  });

  static const double size = 72;
  static const double halo = 96;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> with SingleTickerProviderStateMixin {
  late final _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));

  @override
  void didUpdateWidget(_MicButton old) {
    super.didUpdateWidget(old);
    final started = widget.recording && !old.recording;
    final tick = widget.recording && widget.pulse != old.pulse;
    if (started || tick) {
      _ripple.forward(from: 0);
    } else if (!widget.recording && old.recording) {
      _ripple.stop();
      _ripple.value = 0;
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recording = widget.recording;
    final color = recording ? CvColors.danger : CvColors.primaryDark;

    return SizedBox.square(
      dimension: _MicButton.halo,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Halo
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _MicButton.halo,
            height: _MicButton.halo,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: recording ? CvColors.dangerSoft : CvColors.primarySoft,
            ),
          ),
          // Onda de escucha
          AnimatedBuilder(
            animation: _ripple,
            builder: (context, _) {
              final t = _ripple.value;
              if (!recording || t == 0 || t == 1) return const SizedBox.shrink();
              final d = _MicButton.size + (_MicButton.halo - _MicButton.size) * t;
              return Container(
                width: d,
                height: d,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: CvColors.danger.withValues(alpha: 0.45 * (1 - t)),
                    width: 2,
                  ),
                ),
              );
            },
          ),
          Semantics(
            button: true,
            label: recording ? 'Terminar grabación' : 'Hablar: grabar una acción por voz',
            child: Tooltip(
              message: recording ? 'Terminar grabación' : 'Grabar una acción por voz',
              child: Material(
                key: const Key('voice-mic'),
                color: color,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  hoverColor: Colors.white.withValues(alpha: 0.10),
                  splashColor: Colors.white.withValues(alpha: 0.16),
                  onTap: widget.busy ? null : widget.onPressed,
                  child: SizedBox.square(
                    dimension: _MicButton.size,
                    child: Center(
                      child: widget.busy
                          ? const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                          : Icon(recording ? Icons.stop_rounded : Icons.mic_rounded,
                              color: Colors.white, size: 32),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Señal decorativa del hero: ondas finas derivadas del símbolo CRMVoice,
/// que se desvanecen hacia el contenido.
class _HeroWavePainter extends CustomPainter {
  const _HeroWavePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    final waves = [
      (cycles: 1.6, phase: 0.6, scale: 1.0, alpha: 0.20),
      (cycles: 2.1, phase: 1.7, scale: 0.7, alpha: 0.14),
      (cycles: 1.2, phase: 2.6, scale: 0.45, alpha: 0.10),
    ];
    for (final w in waves) {
      final rect = Rect.fromCenter(
        center: Offset(size.width * 0.62, size.height * 0.5),
        width: size.width * 1.0,
        height: size.height * 0.62 * w.scale,
      );
      canvas.drawPath(
        crmVoiceWavePath(rect, cycles: w.cycles, phase: w.phase),
        Paint()
          ..color = CvColors.primary.withValues(alpha: w.alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
    }
    // Se desvanece hacia la izquierda (zona del texto)
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          colors: [Color(0x00000000), Color(0xFF000000)],
          stops: [0.0, 0.7],
        ).createShader(bounds),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HeroWavePainter old) => false;
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
    return CrmFormShell(
      title: 'Escribir una acción',
      maxWidth: 560,
      busy: _busy,
      actions: [
        FormCancelButton(onPressed: _busy ? null : () => Navigator.pop(context)),
        CvPrimaryButton(
          label: _busy ? 'Interpretando...' : 'Interpretar',
          icon: Icons.arrow_forward_rounded,
          loading: _busy,
          onPressed: _submit,
        ),
      ],
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const AssistantMark(size: 32),
              const SizedBox(width: CvSpace.sm),
              Expanded(
                child: Text('Describe qué quieres hacer en tu CRM, como si lo dijeras en voz alta.',
                    style: CvText.body.copyWith(fontSize: 14.5)),
              ),
            ],
          ),
          const SizedBox(height: CvSpace.lg),
          if (_error != null) FormErrorNotice(message: _error!),
          TextField(
            key: const Key('voice-text-field'),
            controller: _text,
            autofocus: true,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: const InputDecoration(
              hintText: 'Ej.: Mañana a las diez llamar a Ana de Rivera por el portátil Luna 13',
            ),
          ),
          const SizedBox(height: CvSpace.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.lock_outline_rounded, size: 15, color: CvColors.textSecondary),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'CRMVoice la interpretará y podrás revisarla antes de guardar nada.',
                  style: CvText.helper.copyWith(fontSize: 13),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
