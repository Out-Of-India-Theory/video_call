import 'package:flutter/material.dart';
import 'config.dart';
import 'errors.dart';
import 'models/video_user.dart';
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

  static Future<void> init({
    required String apiKey,
    required VideoUser user,
    required TokenProvider tokenProvider,
  }) async {
    _config = OitVideoCallConfig(
      apiKey: apiKey,
      user: user,
      tokenProvider: tokenProvider,
    );
  }

  static Future<void> reset() async {
    _config = null;
  }

  // callScreen() is added in Task 11.
  static Widget callScreen({
    required String callId,
    bool audioOnly = false,
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
    // Real screen wired in Task 27.
    return const Scaffold(
      body: Center(child: Text('CallScreen placeholder — wired in Task 27')),
    );
  }
}
