
import 'oit_video_call_platform_interface.dart';

class OitVideoCall {
  Future<String?> getPlatformVersion() {
    return OitVideoCallPlatform.instance.getPlatformVersion();
  }
}
