import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../active_call/active_call_controller.dart';
import '../active_call/active_call_state.dart';
import '../config.dart';
import '../errors.dart';
import 'error_view.dart';
import 'permission_gate.dart';

@visibleForTesting
class CallScreenDeps {
  const CallScreenDeps({this.permissionGate, this.openSettings});

  final PermissionGate? permissionGate;
  final Future<bool> Function()? openSettings;
}

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.config,
    required this.controller,
    required this.callId,
    required this.callType,
    required this.audioOnly,
    this.createIfMissing = false,
    this.onCallEnded,
    this.confirmLeave,
    @visibleForTesting this.deps,
  });

  final OitVideoCallConfig config;

  /// Owns the call lifecycle (token fetch, connect, get-call, join). The
  /// screen is now a pure consumer — it observes [controller.state] and
  /// triggers a pop when the controller flips back to `idle` (e.g. natural
  /// disconnect handled by a future task).
  final ActiveCallController controller;

  final String callId;
  final String callType;
  final bool audioOnly;
  final bool createIfMissing;
  final VoidCallback? onCallEnded;

  /// Optional gate for the back press. When non-null, the OS back button
  /// won't pop the call screen until this future resolves to `true`. Host
  /// apps wire this to whatever confirmation UI matches their design system
  /// (bottom sheet, dialog, etc.).
  final Future<bool> Function(BuildContext context)? confirmLeave;

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
  late final ActiveCallController _controller = widget.controller;
  late final PermissionGate _gate;
  late final Future<bool> Function() _openSettings;
  _Phase _phase = _Loading();

  /// When `true`, the screen has decided to leave (user confirmed,
  /// disconnect button tapped + confirmed, or the call ended on the
  /// server). PopScope's `canPop` mirrors this so the next pop attempt
  /// goes through instead of being re-intercepted into confirmLeave.
  bool _leaveInProgress = false;

  @override
  void initState() {
    super.initState();
    _gate = widget.deps?.permissionGate ?? RealPermissionGate();
    _openSettings = widget.deps?.openSettings ?? openAppSettings;
    _controller.addListener(_onControllerChanged);
    // Keep the screen on for the duration of the call screen's lifetime.
    // Disabled in dispose. Fire-and-forget — wakelock_plus catches platform
    // exceptions internally and we don't want to gate _start() on it.
    WakelockPlus.enable();
    _start();
  }

  Future<void> _start() async {
    // Phase 1: permissions — stays in the screen because the "open settings"
    // prompt requires BuildContext.
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

    // Phases 2–5 are owned by the controller now.
    final result = await _controller.connectAndJoin(
      config: widget.config,
      callId: widget.callId,
      callType: widget.callType,
      audioOnly: widget.audioOnly,
      createIfMissing: widget.createIfMissing,
    );
    if (!mounted) return;
    setState(() {
      _phase = switch (result) {
        ConnectReady(:final call) => _Ready(call),
        ConnectErrored(:final code, :final message) => _Errored(code, message),
      };
    });
  }

  void _onControllerChanged() {
    // If the controller flips to idle while we're showing a live call
    // (e.g. natural disconnect handled elsewhere — see Task 8), pop the
    // screen out from under us. We deliberately ignore idle transitions
    // that happen while the screen is in a non-Ready phase: those are
    // triggered by [_retry] calling `controller.reset()` to free the
    // state machine for another attempt, and popping the screen would
    // defeat the purpose of the retry.
    if (_controller.state.mode == ActiveCallMode.idle &&
        _phase is _Ready &&
        mounted) {
      _triggerPop();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    WakelockPlus.disable();
    // No `leaveCall` here — controller owns the call lifecycle now.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = _buildScaffold();
    return PopScope(
      // Once a leave is in flight we flip canPop so the next pop attempt
      // (scheduled in [_triggerPop]) actually pops instead of bouncing
      // back into confirmLeave and showing the dialog twice.
      canPop: _leaveInProgress,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Connected → minimize (no confirm). Connecting → preserve v1
        // confirmLeave behavior (cancel join). fastReconnecting also
        // minimizes — the call is real, just temporarily lost.
        final mode = _controller.state.mode;
        if (mode == ActiveCallMode.connected ||
            mode == ActiveCallMode.fastReconnecting) {
          if (_controller.minimize()) {
            // Pop the route now that we're minimized; the host's overlay
            // takes over.
            _triggerPop();
          }
          return;
        }
        // Connecting / errored: fall back to confirmLeave (existing behavior).
        final confirmLeave = widget.confirmLeave;
        if (confirmLeave == null) {
          _triggerPop();
          return;
        }
        final shouldLeave = await confirmLeave(context);
        if (shouldLeave && mounted && context.mounted) {
          await _controller.endCall();
          _triggerPop();
        }
      },
      child: scaffold,
    );
  }

  /// Handler for the in-call AppBar back arrow. When connected (or
  /// recovering), minimize and pop directly so the user sees the mini view
  /// immediately. Otherwise fall through to [PopScope] via `maybePop`,
  /// which runs the same matrix (confirmLeave for connecting/errored).
  void _onBackPressed() {
    final mode = _controller.state.mode;
    if (mode == ActiveCallMode.connected ||
        mode == ActiveCallMode.fastReconnecting) {
      if (_controller.minimize()) _triggerPop();
      return;
    }
    Navigator.of(context).maybePop();
  }

  /// Single funnel for actually popping the call screen. Sets the
  /// `_leaveInProgress` flag so PopScope's `canPop` flips on the next
  /// build, then schedules `Navigator.pop` for the post-frame callback —
  /// by which point the rebuild has happened and the pop sails through.
  void _triggerPop() {
    if (_leaveInProgress || !mounted) return;
    setState(() => _leaveInProgress = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  /// Handler for the in-call leave button (the red disconnect icon in the
  /// app bar). Without this override, [StreamCallContainer] would call
  /// `call.leave()` *before* [confirmLeave] is shown — the call ends
  /// immediately and Cancel can't undo it, leaving the screen stuck on
  /// "Connecting". Routing through here ensures we ask the user first and
  /// only leave (via [_triggerPop]) on confirm.
  Future<void> _onLeaveCallTap() async {
    final confirmLeave = widget.confirmLeave;
    if (confirmLeave != null) {
      final shouldLeave = await confirmLeave(context);
      if (!shouldLeave || !mounted) return;
    }
    _triggerPop();
  }

  /// Handler for non-user-initiated disconnects (call duration timeout,
  /// network drop, host ended). These don't go through [confirmLeave] —
  /// we just pop the screen so the host app's caller can react. Without
  /// this, the SDK's default would be `Navigator.maybePop` which
  /// re-enters our PopScope and shows confirmLeave for an already-ended
  /// call, leaving the screen stuck on "Connecting" if the user cancels.
  void _onCallDisconnected(CallDisconnectedProperties _) {
    _triggerPop();
  }

  Widget _buildScaffold() {
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
        _Ready(call: final call) => StreamCallContainer(
          call: call,
          pictureInPictureConfiguration: const PictureInPictureConfiguration(
            enablePictureInPicture: true,
          ),
          onBackPressed: _onBackPressed,
          onLeaveCallTap: () => unawaited(_onLeaveCallTap()),
          onCallDisconnected: _onCallDisconnected,
        ),
      },
    );
  }

  void _retry() {
    // The controller refuses to re-connect when its state isn't `idle` — it
    // would otherwise either silently return the existing call (not what we
    // want after an error, since the failed attempt left no `Call` behind)
    // or short-circuit to `connecting` and dead-end. Reset first so the
    // state machine accepts the new attempt.
    _controller.reset();
    setState(() => _phase = _Loading());
    _start();
  }
}
