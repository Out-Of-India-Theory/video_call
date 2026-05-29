import 'package:oit_video_call/src/screen/permission_gate.dart';

/// In-memory [PermissionGate] for unit tests. Set [result] before the screen
/// requests permissions to drive the granted / denied / permanently-denied
/// branches; assert [requestCount] / [lastIncludeCamera] afterwards.
class FakePermissionGate implements PermissionGate {
  PermissionResult result = const PermissionResult(
    microphoneGranted: true,
    cameraGranted: true,
  );
  bool? lastIncludeCamera;
  int requestCount = 0;

  @override
  Future<PermissionResult> request({required bool includeCamera}) async {
    requestCount++;
    lastIncludeCamera = includeCamera;
    return result;
  }
}
