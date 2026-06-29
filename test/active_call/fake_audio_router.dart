import 'package:oit_video_call/src/active_call/audio_router.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// No-op [AudioRouter] for unit tests: records `attach`/`detach` calls without
/// touching the real [RtcMediaDeviceNotifier] singleton (whose constructor
/// wires a WebRTC `EventChannel` and therefore needs platform bindings that
/// plain `test()` hosts don't initialize). Inject it anywhere a controller is
/// driven to a connected call — mirrors the `FakeCallSession` pattern.
class FakeAudioRouter implements AudioRouter {
  final List<Call> attached = <Call>[];
  int detachCount = 0;

  @override
  Future<void> attach(Call call) async {
    attached.add(call);
  }

  @override
  Future<void> detach() async {
    detachCount++;
  }
}
