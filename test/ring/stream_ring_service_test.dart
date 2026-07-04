import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/ring/stream_ring_service.dart';

void main() {
  // debugActive is process-wide singleton state; keep tests isolated.
  tearDown(() => StreamRingService.instance.debugActive = false);

  test('isActive defaults to false and is a singleton', () {
    expect(StreamRingService.instance, same(StreamRingService.instance));
    expect(StreamRingService.instance.isActive, isFalse);
  });

  test('debugActive flips isActive for reuse-guard testing', () {
    StreamRingService.instance.debugActive = true;
    expect(StreamRingService.instance.isActive, isTrue);
    StreamRingService.instance.debugActive = false;
    expect(StreamRingService.instance.isActive, isFalse);
  });

  // The audio-policy methods reconfigure native audio via
  // RtcMediaDeviceNotifier.instance, which is unavailable in the test VM. Both
  // guard on `isActive` and return early when the ring connection isn't the
  // active audio owner — so they must NEVER touch the notifier then (the
  // per-call StreamVideo already has the SDK-default Broadcaster policy). These
  // completing normally proves the guard holds; a regression that dropped the
  // guard would throw a MissingPluginException here.
  test('applyCallAudioPolicy is a no-op when the ring connection is inactive',
      () async {
    StreamRingService.instance.debugActive = false;
    await StreamRingService.instance.applyCallAudioPolicy();
  });

  test('restoreRingAudioPolicy is a no-op when the ring connection is inactive',
      () async {
    StreamRingService.instance.debugActive = false;
    await StreamRingService.instance.restoreRingAudioPolicy();
  });
}
