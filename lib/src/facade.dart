import 'package:flutter/widgets.dart';
import 'config.dart';
import 'models/video_user.dart';

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
    throw UnimplementedError('Wired in Task 11');
  }
}
