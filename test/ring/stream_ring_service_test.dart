import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/ring/stream_ring_service.dart';

void main() {
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
}
