import 'package:flutter/material.dart';
import 'active_call/active_call_controller.dart';
import 'config.dart';
import 'errors.dart';
import 'models/video_user.dart';
import 'screen/call_screen.dart';
import 'screen/error_view.dart';

/// Snapshot of the parameters last passed to [OitVideoCall.callScreen].
///
/// Cached on the facade so the plugin-handled tap-to-expand fallback in
/// [OitVideoCallHost] can rebuild an equivalent [CallScreen] without the host
/// app having to re-supply the call id, type, etc.
///
/// Read it via [OitVideoCall.lastArgsOrNull]. The fields are intentionally
/// the surface area of [OitVideoCall.callScreen] so apps and the host stay in
/// sync if either side adds a new argument.
class CallScreenArgs {
  const CallScreenArgs({
    required this.callId,
    required this.callType,
    required this.audioOnly,
    required this.createIfMissing,
    required this.onCallEnded,
    required this.confirmLeave,
  });

  final String callId;
  final String callType;
  final bool audioOnly;
  final bool createIfMissing;
  final VoidCallback? onCallEnded;
  final Future<bool> Function(BuildContext context)? confirmLeave;
}

class OitVideoCall {
  OitVideoCall._();

  static OitVideoCallConfig? _config;
  static ActiveCallController? _controller;
  static CallScreenArgs? _lastArgs;

  /// Notifies subscribers when [_controller] is replaced (init, initForTest,
  /// or reset). [OitVideoCallHost] uses this to attach lazily — apps can
  /// mount the host before calling [init] (e.g. wrapping `MaterialApp.builder`
  /// at app startup while [init] runs after login) and the host will hook up
  /// the moment [init] runs.
  static final ValueNotifier<ActiveCallController?>
      activeControllerListenable = ValueNotifier<ActiveCallController?>(null);

  static bool get isInitialized => _config != null;

  /// The arguments most recently passed to [callScreen], or `null` if the
  /// call screen has never been built in this process. Read-only — the host
  /// uses this to rebuild [CallScreen] when expanding from the minimized view
  /// without the app having wired its own [OitVideoCallHost.onExpandRequested].
  static CallScreenArgs? get lastArgsOrNull => _lastArgs;

  static OitVideoCallConfig get configOrThrow {
    final c = _config;
    if (c == null) {
      throw StateError('OitVideoCall.init() has not been called.');
    }
    return c;
  }

  static ActiveCallController get controllerOrThrow {
    final c = _controller;
    if (c == null) {
      throw StateError('OitVideoCall.init() has not been called.');
    }
    return c;
  }

  static void init({
    required String apiKey,
    required VideoUser user,
    required TokenProvider tokenProvider,
  }) {
    _config = OitVideoCallConfig(
      apiKey: apiKey,
      user: user,
      tokenProvider: tokenProvider,
    );
    _controller = ActiveCallController();
    activeControllerListenable.value = _controller;
  }

  /// Test-only setup that lets host-widget tests bring their own
  /// [ActiveCallController] (typically constructed with a `FakeCallSession`)
  /// so they can drive it into `connected` / `minimized` modes deterministically
  /// before pumping [OitVideoCallHost]. Production code paths through [init]
  /// are unaffected.
  @visibleForTesting
  static void initForTest({
    required OitVideoCallConfig config,
    required ActiveCallController controller,
  }) {
    _config = config;
    _controller = controller;
    activeControllerListenable.value = _controller;
  }

  static Future<void> reset() async {
    await _controller?.endCall();
    _controller = null;
    _config = null;
    _lastArgs = null;
    activeControllerListenable.value = null;
  }

  /// Ends the active call (if any) without tearing down the singleton.
  /// Delegates to [ActiveCallController.endCall].
  ///
  /// When [forEveryone] is true, attempts to terminate the call for all
  /// participants on the Stream coordinator (used by the mitra-side
  /// order-completion flow to close the room when an astrologer marks a
  /// consultation complete). Falls back to a plain leave if the server
  /// rejects the end-for-all request so the local user is always out.
  ///
  /// Errors during teardown are swallowed inside the controller; this
  /// never throws. No-op when [init] hasn't been called or the controller
  /// is already idle.
  static Future<void> endCall({bool forEveryone = false}) async {
    await _controller?.endCall(forEveryone: forEveryone);
  }

  static Widget callScreen({
    required String callId,
    bool audioOnly = false,
    bool createIfMissing = false,
    String callType = 'default',
    VoidCallback? onCallEnded,
    Future<bool> Function(BuildContext context)? confirmLeave,
  }) {
    if (_config == null || _controller == null) {
      return const Scaffold(
        body: ErrorView(
          code: OitVideoCallErrorCode.notInitialized,
          message:
              'OitVideoCall is not initialized. Call OitVideoCall.init() first.',
        ),
      );
    }
    // Cache for the plugin-handled tap-to-expand fallback in
    // [OitVideoCallHost]. Updated on every call so the most recently mounted
    // call screen wins (the only one that can be live).
    _lastArgs = CallScreenArgs(
      callId: callId,
      callType: callType,
      audioOnly: audioOnly,
      createIfMissing: createIfMissing,
      onCallEnded: onCallEnded,
      confirmLeave: confirmLeave,
    );
    return CallScreen(
      config: _config!,
      controller: _controller!,
      callId: callId,
      callType: callType,
      audioOnly: audioOnly,
      createIfMissing: createIfMissing,
      onCallEnded: onCallEnded,
      confirmLeave: confirmLeave,
    );
  }
}
