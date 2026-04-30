import 'package:flutter/material.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart' show StreamVideo;
import 'config.dart';
import 'errors.dart';
import 'models/video_user.dart';
import 'screen/call_screen.dart';
import 'screen/error_view.dart';

class OitVideoCall {
  OitVideoCall._();

  static OitVideoCallConfig? _config;

  static bool get isInitialized => _config != null;

  static OitVideoCallConfig get configOrThrow {
    final c = _config;
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
  }

  static Future<void> reset() async {
    _config = null;
    await StreamVideo.reset();
  }

  // callScreen() is added in Task 11.
  static Widget callScreen({
    required String callId,
    bool audioOnly = false,
    bool createIfMissing = false,
    String callType = 'default',
    VoidCallback? onCallEnded,
  }) {
    if (_config == null) {
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
      callId: callId,
      callType: callType,
      audioOnly: audioOnly,
      createIfMissing: createIfMissing,
      onCallEnded: onCallEnded,
    );
  }
}
