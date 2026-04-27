import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'oit_video_call_method_channel.dart';

abstract class OitVideoCallPlatform extends PlatformInterface {
  /// Constructs a OitVideoCallPlatform.
  OitVideoCallPlatform() : super(token: _token);

  static final Object _token = Object();

  static OitVideoCallPlatform _instance = MethodChannelOitVideoCall();

  /// The default instance of [OitVideoCallPlatform] to use.
  ///
  /// Defaults to [MethodChannelOitVideoCall].
  static OitVideoCallPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [OitVideoCallPlatform] when
  /// they register themselves.
  static set instance(OitVideoCallPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
