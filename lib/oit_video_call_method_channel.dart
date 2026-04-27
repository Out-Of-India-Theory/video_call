import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'oit_video_call_platform_interface.dart';

/// An implementation of [OitVideoCallPlatform] that uses method channels.
class MethodChannelOitVideoCall extends OitVideoCallPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('oit_video_call');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
