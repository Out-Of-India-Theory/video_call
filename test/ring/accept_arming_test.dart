import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/ring/stream_ring_service.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../screen/fake_call_session.dart';

void main() {
  group('AcceptArming', () {
    test('delivers the first accept and reports it in flight', () {
      final a = AcceptArming();
      expect(a.hasInFlight, isFalse);
      expect(a.shouldDeliver('order-1', inFlightIsLive: false), isTrue);
      expect(a.hasInFlight, isTrue);
    });

    test('dedupes a duplicate report of the same in-flight accept', () {
      // The live observer + the cold-start consume poll can both report the
      // SAME accept; only the first must navigate. Holds whether or not the
      // call has come up yet — the join takes seconds.
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1', inFlightIsLive: false), isTrue);
      expect(a.shouldDeliver('order-1', inFlightIsLive: false), isFalse);
      expect(a.shouldDeliver('order-1', inFlightIsLive: true), isFalse);
    });

    test('drops a different accept while the in-flight call is LIVE', () {
      // An accidental tap on a second incoming call must not yank someone out
      // of the call they are in.
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1', inFlightIsLive: false), isTrue);
      expect(a.shouldDeliver('order-2', inFlightIsLive: true), isFalse);
      expect(a.debugInFlightCallId, 'order-1', reason: 'latch must not move');
    });

    test('a different accept SUPERSEDES a latch whose call is not live', () {
      // mitra #435. The black hole: an accept whose call never joined never
      // reports isDisconnected, so callEnded never fires and the latch outlives
      // the call. Every later accept was then dropped for the rest of the
      // process while the SDK — which joins BEFORE the accept callback runs —
      // held camera and mic with no UI. A dead latch must yield.
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1', inFlightIsLive: false), isTrue);
      expect(a.shouldDeliver('order-2', inFlightIsLive: false), isTrue);
      expect(a.debugInFlightCallId, 'order-2');
    });

    test('re-arms after the in-flight call ends so the SAME cid rings again',
        () {
      // #5205: a consultation reuses ONE call cid across rings (server T-5,
      // server/mitra T+2 re-ring). The prior latch dropped every accept after
      // the first, so the app never navigated into the rejoined call.
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1', inFlightIsLive: false), isTrue);
      a.callEnded('order-1');
      expect(a.hasInFlight, isFalse);
      expect(a.shouldDeliver('order-1', inFlightIsLive: true), isTrue,
          reason: 're-ring must deliver');
    });

    test('callEnded for a non-matching id is a no-op', () {
      final a = AcceptArming();
      expect(a.shouldDeliver('order-1', inFlightIsLive: false), isTrue);
      a.callEnded('order-2'); // stale subscription from a previous call
      expect(a.hasInFlight, isTrue);
      expect(a.shouldDeliver('order-1', inFlightIsLive: true), isFalse);
    });

    test('reset clears in-flight state', () {
      final a = AcceptArming();
      a.shouldDeliver('order-1', inFlightIsLive: false);
      a.reset();
      expect(a.hasInFlight, isFalse);
      expect(a.shouldDeliver('order-1', inFlightIsLive: true), isTrue);
    });
  });

  group('watchCallEnd — re-arm wiring (#5205)', () {
    // The whole #5205 fix hinges on this listener firing exactly once when the
    // accepted call disconnects. Drives the REAL call.state.listen path with
    // the existing FakeCallSession fake Call (sync broadcast emitter).
    test('fires onEnded once on disconnect, ignores connected, self-cancels',
        () async {
      final session = FakeCallSession();
      final call = await session.getCall(callType: 'default', callId: 'order-1');
      var ended = 0;
      final sub = StreamRingService.watchCallEnd(call, () => ended++);
      addTearDown(sub.cancel);

      // Non-terminal transition must NOT re-arm.
      session.pushCallStatus(CallStatus.connected());
      expect(ended, 0);

      // First disconnect fires exactly once.
      session.pushCallStatus(CallStatus.disconnected(DisconnectReason.ended()));
      expect(ended, 1);

      // Subscription self-cancelled — a later disconnect does nothing.
      session.pushCallStatus(CallStatus.disconnected(DisconnectReason.ended()));
      expect(ended, 1);
    });
  });

  group('orphaned accept timeout', () {
    test('is generous enough for a cold-start mount', () {
      // Accept → app boot → consultation load → call screen measured a few
      // seconds on a real device. The timeout only has to bound the leak, so it
      // must stay well clear of a slow-but-legitimate mount: shortening this
      // would leave a call the user was about to see.
      expect(StreamRingService.orphanedAcceptTimeout.inSeconds,
          greaterThanOrEqualTo(30));
    });
  });
}
