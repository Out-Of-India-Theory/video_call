import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/ring/stream_ring_service.dart';

void main() {
  group('AcceptArming', () {
    test('delivers the first accept and reports it in flight', () {
      final a = AcceptArming();
      expect(a.hasInFlight, isFalse);
      expect(a.shouldDeliver('order-1'), isTrue);
      expect(a.hasInFlight, isTrue);
    });

    test('dedupes a duplicate report of the same in-flight accept', () {
      // The live observer + the cold-start consume poll can both report the
      // SAME accept; only the first must navigate.
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1'), isTrue);
      expect(a.shouldDeliver('order-1'), isFalse);
    });

    test('drops a different accept while one is already in flight', () {
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1'), isTrue);
      expect(a.shouldDeliver('order-2'), isFalse);
    });

    test('re-arms after the in-flight call ends so the SAME cid rings again', () {
      // #5205: a consultation reuses ONE call cid across rings (server T-5,
      // server/mitra T+2 re-ring). The prior latch dropped every accept after
      // the first, so the app never navigated into the rejoined call.
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1'), isTrue);
      a.callEnded('order-1');
      expect(a.hasInFlight, isFalse);
      expect(a.shouldDeliver('order-1'), isTrue, reason: 're-ring must deliver');
    });

    test('callEnded for a non-matching id is a no-op', () {
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1'), isTrue);
      a.callEnded('order-2'); // stale subscription from a previous call
      expect(a.hasInFlight, isTrue);
      expect(a.shouldDeliver('order-1'), isFalse);
    });

    test('reset clears in-flight state', () {
      final a = AcceptArming();
      a.shouldDeliver('order-1');
      a.reset();
      expect(a.hasInFlight, isFalse);
      expect(a.shouldDeliver('order-1'), isTrue);
    });
  });
}
