import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/oit_video_call.dart';
import 'package:oit_video_call/oit_video_call_platform_interface.dart';
import 'package:oit_video_call/oit_video_call_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockOitVideoCallPlatform
    with MockPlatformInterfaceMixin
    implements OitVideoCallPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final OitVideoCallPlatform initialPlatform = OitVideoCallPlatform.instance;

  test('$MethodChannelOitVideoCall is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelOitVideoCall>());
  });

  test('getPlatformVersion', () async {
    OitVideoCall oitVideoCallPlugin = OitVideoCall();
    MockOitVideoCallPlatform fakePlatform = MockOitVideoCallPlatform();
    OitVideoCallPlatform.instance = fakePlatform;

    expect(await oitVideoCallPlugin.getPlatformVersion(), '42');
  });
}
