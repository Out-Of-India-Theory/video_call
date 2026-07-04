import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/ring/stream_ring_service.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

void main() {
  // debugActive + the platform override are process-wide; keep tests isolated.
  tearDown(() {
    StreamRingService.instance.debugActive = false;
    debugDefaultTargetPlatformOverride = null;
  });

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

  group('ringReceptionAudioPolicy', () {
    // iOS renders incoming rings via CallKit (system UI), so the long-lived ring
    // connection can hold BroadcasterAudioPolicy — echo cancellation stays on
    // for the live call. Returning ViewerAudioPolicy here (the pre-fix value)
    // left AEC off, and the remote party heard echo whenever an iOS device was
    // in the call (consumer 6.7.5 / mitra 1.8.5).
    test('is Broadcaster on iOS (CallKit ring, AEC on for the call)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(ringReceptionAudioPolicy(), isA<BroadcasterAudioPolicy>());
    });

    // Android's communication mode DUCKS the ringtone, so the ring connection
    // stays on media playback for a loud ring; the live call still gets AEC from
    // the per-call Broadcaster preference (Android-to-Android has no echo).
    test('is Viewer on Android (loud ring)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(ringReceptionAudioPolicy(), isA<ViewerAudioPolicy>());
    });
  });

  // restoreRingAudioPolicy reconfigures native audio via
  // RtcMediaDeviceNotifier.instance (unavailable in the test VM); it guards on
  // isActive and must return early when inactive — completing normally here
  // proves the guard holds (a regression dropping it would throw).
  test('restoreRingAudioPolicy is a no-op when the ring connection is inactive',
      () async {
    StreamRingService.instance.debugActive = false;
    await StreamRingService.instance.restoreRingAudioPolicy();
  });
}
