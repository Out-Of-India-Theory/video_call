import 'package:flutter/material.dart';
import 'active_call/active_call_controller.dart';
import 'config.dart';
import 'errors.dart';
import 'host/oit_video_call_host.dart';
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
  }

  /// Test-only setup that lets host-widget tests bring their own
  /// [ActiveCallController] (typically constructed with a `FakeCallSession`)
  /// so they can drive it into `connected` / `minimized` modes deterministically
  /// before pumping [OitVideoCallHost]. Production code paths through [init]
  /// are unaffected.
  @visibleForTesting
  static void debugInitForTest({
    required OitVideoCallConfig config,
    required ActiveCallController controller,
  }) {
    _config = config;
    _controller = controller;
  }

  static Future<void> reset() async {
    await _controller?.endCall();
    _controller = null;
    _config = null;
    _lastArgs = null;
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

  static Widget host({
    required Widget child,
    Widget Function(BuildContext, ActiveCallController)? minimizedBuilder,
    VoidCallback? onExpandRequested,
  }) =>
      OitVideoCallHost(
        minimizedBuilder: minimizedBuilder,
        onExpandRequested: onExpandRequested,
        child: child,
      );
}
