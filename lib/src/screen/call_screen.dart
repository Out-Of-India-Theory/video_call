import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../active_call/active_call_controller.dart';
import '../active_call/active_call_state.dart';
import '../config.dart';
import '../errors.dart';
import 'background_effect_option.dart';
import 'error_view.dart';
import 'permission_gate.dart';
import 'waiting_banner_gate.dart';

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
    this.waitingForOtherParticipant,
    this.callOverlay,
    this.onSystemEnded,
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

  /// Optional widget rendered over the call screen while the local user is
  /// alone in the call (no remote participants yet).
  final Widget? waitingForOtherParticipant;

  /// Optional widget rendered persistently over the live call (below the
  /// call app bar) for the whole connected duration. The host owns its
  /// content, timing, dismissal, and copy — e.g. the user app's dismissable
  /// "2 minutes left" nudge or the jyotishi app's always-on countdown bar.
  /// This package neither ends the call at any cap (the backend owns
  /// termination) nor interprets the overlay; it just draws it.
  ///
  /// It is pinned full-width just below the call app bar and stacked above the
  /// waiting banner in an unbounded [Column], so **the host is responsible for
  /// keeping it compact**: a tall overlay extends down over the call content,
  /// and any opaque/hit-testable region intercepts taps meant for the video
  /// below it (wrap non-interactive content in an [IgnorePointer]).
  final Widget? callOverlay;

  /// Invoked once when the SDK reports the call was ended by the **system** —
  /// a backend `call.ended` with no `endedBy` user (i.e. the hard time cap) —
  /// rather than by a participant. Lets the host distinguish a system
  /// termination (→ e.g. rebook / "time complete") from a user/jyotishi leave
  /// or a network drop, for which it is NOT called.
  final VoidCallback? onSystemEnded;

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
    // System-end detection lives on the controller (which outlives this
    // screen) so a hard-cap end that arrives while the call is minimized / in
    // PiP is still detected. Wire the host's callback before [_start] so the
    // controller's callEvents subscription is attached with it in place. On a
    // tap-to-expand remount this re-sets the same callback — harmless, and the
    // controller's already-live subscription keeps running untouched.
    _controller.onSystemEnded = widget.onSystemEnded;
    _controller.addListener(_onControllerChanged);
    // Keep the screen on for the duration of the call screen's lifetime.
    // Disabled in dispose. Fire-and-forget — wakelock_plus catches platform
    // exceptions internally and we don't want to gate _start() on it.
    WakelockPlus.enable();
    // If we were just remounted via tap-to-expand from the host's mini
    // overlay, the controller is in `minimized` mode. Flip it back to
    // `connected` here (rather than from the host) so the mini overlay
    // doesn't disappear for a frame before this screen has rendered. The
    // call already has a live `Call`, so `_start()` below short-circuits
    // through `connectAndJoin`'s "already connected" branch. We only flip
    // when the callId matches — otherwise the host has pushed us for a
    // different call while the controller is still minimized for an old
    // one, and unconditionally flipping would corrupt the controller's
    // state (mode=connected but callId pointing at the wrong call).
    // `_start()` will then throw via `connectAndJoin`'s state check.
    if (_controller.state.mode == ActiveCallMode.minimized &&
        _controller.state.callId == widget.callId) {
      _controller.expand();
    }
    _start();
  }

  Future<void> _start() async {
    // Phase 1: permissions — stays in the screen because the "open settings"
    // prompt requires BuildContext.
    //
    // Microphone is mandatory (no audio = can't participate). Camera is
    // best-effort: if the user declines, we downgrade to audio-only and
    // proceed with the join rather than block — the user can still
    // hear/talk and can grant camera mid-call via the in-call toggle.
    // This also makes us more resilient to one-permission-fails edge cases
    // on web (e.g. browsers that silently fail the camera getUserMedia
    // while microphone succeeds).
    final perm = await _gate.request(includeCamera: !widget.audioOnly);
    if (!mounted) return;
    if (!perm.microphoneGranted) {
      // Mobile: offer "Open Settings" rather than Retry. Retry is unreliable —
      // on iOS the OS returns "denied" immediately on subsequent request()
      // calls without re-prompting; on Android once the user hits "Don't ask
      // again" Retry stops working. Settings always works.
      //
      // Web: invert the buttons. `openAppSettings()` from permission_handler
      // is a no-op on web (returns SynchronousFuture(false)) since there is
      // no programmatic way to open browser permission settings. Retry is
      // useful instead: `permission_handler_html` calls `getUserMedia(...)`
      // directly, so a second request re-prompts when the user merely
      // dismissed the prompt, and silently fails when they hard-blocked —
      // in which case the copy points them to the address-bar icon, after
      // which Retry succeeds.
      const message = kIsWeb
          ? 'Microphone access is required. Click the microphone icon '
                'in your browser\'s address bar to allow access, then tap '
                'Retry. If Retry keeps failing, reload the page.'
          : 'Microphone access is required. Tap "Open Settings" to enable.';
      setState(
        () => _phase = _Errored(
          OitVideoCallErrorCode.permissionDenied,
          message,
          canRetry: kIsWeb,
          canOpenSettings: !kIsWeb,
        ),
      );
      return;
    }

    // Camera is best-effort. When not granted (either because the user
    // declined or because we didn't ask — audio-only), downgrade the join
    // so `connectAndJoin` runs `setCameraEnabled(false)` post-join and
    // the SDK doesn't try to publish a video track without permission.
    final effectiveAudioOnly = widget.audioOnly || !perm.cameraGranted;

    // Phases 2–5 are owned by the controller now.
    final result = await _controller.connectAndJoin(
      config: widget.config,
      callId: widget.callId,
      callType: widget.callType,
      audioOnly: effectiveAudioOnly,
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
    // No `leaveCall` here — controller owns the call lifecycle now. The
    // system-end callEvents subscription lives on the controller too, so it
    // survives this dispose (e.g. a hard-cap end while minimized).
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
  /// "Connecting". Routing through here ensures we ask the user first and,
  /// on confirm, end the call via the controller (mirroring the PopScope
  /// no-minimize branch) before popping.
  Future<void> _onLeaveCallTap() async {
    final confirmLeave = widget.confirmLeave;
    if (confirmLeave != null) {
      final shouldLeave = await confirmLeave(context);
      if (!shouldLeave || !mounted) return;
    }
    await _controller.endCall();
    if (!mounted) return;
    _triggerPop();
  }

  /// Handler for non-user-initiated disconnects (call duration timeout,
  /// network drop, host ended). These don't go through [confirmLeave] —
  /// we just pop the screen so the host app's caller can react. Without
  /// this, the SDK's default would be `Navigator.maybePop` which
  /// re-enters our PopScope and shows confirmLeave for an already-ended
  /// call, leaving the screen stuck on "Connecting" if the user cancels.
  void _onCallDisconnected(CallDisconnectedProperties props) {
    // Just pop — system-end classification is NOT done here. The SDK collapses
    // every call-ended scenario (system hard-cap AND jyotishi
    // end-for-everyone) to `DisconnectReason.ended()`, discarding `endedBy`, so
    // this reason cannot tell them apart and would fire `onSystemEnded` on a
    // normal jyotishi end. The sound signal is the coordinator
    // `StreamCallEndedEvent.endedBy`, watched on the controller
    // ([ActiveCallController._watchSystemEnd]) which outlives this screen.
    debugPrint(
      '[oit_video_call] onCallDisconnected → reason=${props.reason.runtimeType}',
    );
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
        _Ready(call: final call) => Stack(
          children: [
            StreamCallContainer(
              call: call,
              pictureInPictureConfiguration:
                  const PictureInPictureConfiguration(
                enablePictureInPicture: true,
              ),
              onBackPressed: _onBackPressed,
              onLeaveCallTap: () => unawaited(_onLeaveCallTap()),
              onCallDisconnected: _onCallDisconnected,
              // Override the default controls bar to drop the speakerphone
              // toggle on every platform. Audio output is now managed
              // automatically by [StreamAudioRouter] (connected headset, else
              // loudspeaker), so a manual speaker toggle is redundant and was
              // confusing — its "off" position routed to a plugged-in headset,
              // reading as an output switch (dharmayana_app#4957). On web we
              // also drop flip-camera (Stream's impl bridges to mobile WebRTC
              // switchCamera and no-ops in browsers); mobile keeps it.
              callContentWidgetBuilder: (context, call) => StreamCallContent(
                call: call,
                onBackPressed: _onBackPressed,
                onLeaveCallTap: () => unawaited(_onLeaveCallTap()),
                pictureInPictureConfiguration:
                    const PictureInPictureConfiguration(
                  enablePictureInPicture: true,
                ),
                callControlsWidgetBuilder: (_, call) => StreamCallControls(
                  options: kIsWeb
                      ? webCallControlOptions(call: call)
                      : mobileCallControlOptions(call: call),
                ),
              ),
            ),
            // Offset by status bar + Material AppBar height so the overlays sit
            // just below Stream's CallAppBar instead of overlapping the
            // back/leave controls. The host-owned persistent overlay
            // (time-limit nudge / countdown bar) and the waiting banner stack
            // vertically in a Column so they never overlap: the persistent
            // overlay stays pinned on top while the waiting banner sits below
            // and collapses to zero once the remote joins.
            if (widget.callOverlay != null ||
                widget.waitingForOtherParticipant != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + kToolbarHeight,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.callOverlay != null) widget.callOverlay!,
                    if (widget.waitingForOtherParticipant != null)
                      WaitingBannerGate(
                        call: call,
                        child: widget.waitingForOtherParticipant!,
                      ),
                  ],
                ),
              ),
          ],
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

/// Web-only call control bar — Stream's default option set minus the
/// speakerphone toggle and flip-camera button, which are mobile-only and
/// silently no-op on web.
@visibleForTesting
List<Widget> webCallControlOptions({required Call call}) => [
      ToggleCameraOption(call: call),
      ToggleMicrophoneOption(call: call),
    ];

/// Mobile call control bar — Stream's default option set
/// ([defaultCallControlOptions]) minus the speakerphone toggle. Audio output
/// is managed automatically by [StreamAudioRouter] (connected headset, else
/// loudspeaker), so the manual toggle is redundant (dharmayana_app#4957).
/// Flip-camera is kept — it's functional on mobile.
@visibleForTesting
List<Widget> mobileCallControlOptions({required Call call}) => [
      ToggleCameraOption(call: call),
      BackgroundEffectOption(call: call),
      ToggleMicrophoneOption(call: call),
      FlipCameraOption(call: call),
    ];
