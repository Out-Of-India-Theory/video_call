import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../config.dart';
import '../errors.dart';
import 'call_session.dart';
import 'error_view.dart';
import 'permission_gate.dart';

@visibleForTesting
class CallScreenDeps {
  const CallScreenDeps({this.session, this.permissionGate, this.openSettings});

  final CallSession? session;
  final PermissionGate? permissionGate;
  final Future<bool> Function()? openSettings;
}

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.config,
    required this.callId,
    required this.callType,
    required this.audioOnly,
    this.createIfMissing = false,
    this.onCallEnded,
    @visibleForTesting this.deps,
  });

  final OitVideoCallConfig config;
  final String callId;
  final String callType;
  final bool audioOnly;
  final bool createIfMissing;
  final VoidCallback? onCallEnded;

  @visibleForTesting
  final CallScreenDeps? deps;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

sealed class _Phase {}

class _Loading extends _Phase {}

class _Errored extends _Phase {
  _Errored(
    this.code,
    this.message, {
    this.canRetry = true,
    this.canOpenSettings = false,
  });

  final OitVideoCallErrorCode code;
  final String message;
  final bool canRetry;
  final bool canOpenSettings;
}

class _Ready extends _Phase {
  _Ready(this.call);

  final Call call;
}

class _CallScreenState extends State<CallScreen> {
  late final CallSession _session;
  late final PermissionGate _gate;
  late final Future<bool> Function() _openSettings;
  Call? _call;
  _Phase _phase = _Loading();

  @override
  void initState() {
    super.initState();
    _session = widget.deps?.session ?? StreamCallSession();
    _gate = widget.deps?.permissionGate ?? RealPermissionGate();
    _openSettings = widget.deps?.openSettings ?? openAppSettings;
    // Keep the screen on for the duration of the call screen's lifetime.
    // Disabled in dispose. Fire-and-forget — wakelock_plus catches platform
    // exceptions internally and we don't want to gate _start() on it.
    WakelockPlus.enable();
    _start();
  }

  Future<void> _start() async {
    // Phase 1: permissions
    final perm = await _gate.request(includeCamera: !widget.audioOnly);
    if (!mounted) return;
    if (!perm.granted) {
      // Always offer "Open Settings" rather than Retry. Retry is unreliable:
      // on iOS the OS returns "denied" immediately on subsequent request()
      // calls without re-prompting; on Android once the user hits "Don't ask
      // again" Retry stops working. Settings always works.
      final scope = widget.audioOnly ? 'Microphone' : 'Camera and microphone';
      setState(
        () => _phase = _Errored(
          OitVideoCallErrorCode.permissionDenied,
          '$scope access is required. Tap "Open Settings" to enable.',
          canRetry: false,
          canOpenSettings: true,
        ),
      );
      return;
    }

    // Phase 2: token
    final String token;
    try {
      token = await widget.config.tokenProvider();
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _phase = _Errored(
          OitVideoCallErrorCode.tokenFetchFailed,
          'Could not fetch call token.',
        ),
      );
      return;
    }

    // Phase 3: connect
    try {
      final user = User.regular(
        userId: widget.config.user.id,
        name: widget.config.user.name,
        image: widget.config.user.image,
      );
      await _session.connect(
        apiKey: widget.config.apiKey,
        user: user,
        token: token,
      );
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _phase = _Errored(
          OitVideoCallErrorCode.joinFailed,
          'Could not connect to call service.',
        ),
      );
      return;
    }

    // Phase 4: get call (no create) — or get-or-create if requested
    final Call call;
    try {
      call = widget.createIfMissing
          ? await _session.getOrCreateCall(
              callType: widget.callType, callId: widget.callId)
          : await _session.getCall(
              callType: widget.callType, callId: widget.callId);
    } on CallNotFoundError {
      if (!mounted) return;
      setState(
        () => _phase = _Errored(
          OitVideoCallErrorCode.callNotFound,
          'Call not available.',
        ),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _phase = _Errored(
          OitVideoCallErrorCode.joinFailed,
          widget.createIfMissing
              ? 'Could not start call.'
              : 'Could not load call.',
        ),
      );
      return;
    }

    // Phase 5: join
    try {
      await _session.joinCall(call);
      if (widget.audioOnly) {
        await _session.setCameraEnabled(call, false);
      }
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _phase = _Errored(
          OitVideoCallErrorCode.joinFailed,
          'Could not join call.',
        ),
      );
      return;
    }

    if (!mounted) return;
    _call = call;
    setState(() => _phase = _Ready(call));
  }

  @override
  void dispose() {
    if (_call != null) {
      _session.leaveCall(_call!);
    }
    _session.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_phase) {
        _Loading() => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Joining call…'),
            ],
          ),
        ),
        _Errored(
          code: final c,
          message: final m,
          canRetry: final r,
          canOpenSettings: final s,
        ) =>
          ErrorView(
            code: c,
            message: m,
            onRetry: r ? _retry : null,
            onOpenSettings: s ? () => _openSettings() : null,
          ),
        _Ready(call: final call) => StreamCallContainer(call: call),
      },
    );
  }

  void _retry() {
    setState(() => _phase = _Loading());
    _start();
  }
}
