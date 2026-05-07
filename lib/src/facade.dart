import 'package:flutter/material.dart';
import 'active_call/active_call_controller.dart';
import 'config.dart';
import 'errors.dart';
import 'host/oit_video_call_host.dart';
import 'models/video_user.dart';
import 'screen/call_screen.dart';
import 'screen/error_view.dart';

class OitVideoCall {
  OitVideoCall._();

  static OitVideoCallConfig? _config;
  static ActiveCallController? _controller;

  static bool get isInitialized => _config != null;

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

  static Future<void> reset() async {
    await _controller?.endCall();
    _controller = null;
    _config = null;
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
