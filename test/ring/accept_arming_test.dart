import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/ring/stream_ring_service.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../screen/fake_call_session.dart';

void main() {
  group('AcceptArming', () {
    test('delivers the first accept and reports it in flight', () {
      final a = AcceptArming();
      expect(a.hasInFlight, isFalse);
      expect(a.decide('order-1', inFlightIsLive: false), AcceptDecision.deliver);
      expect(a.hasInFlight, isTrue);
    });

    test('dedupes a duplicate report of the same in-flight accept', () {
      // The live observer + the cold-start consume poll can both report the
      // SAME accept; only the first must navigate. Holds whether or not the
      // call has come up yet — the join takes seconds.
      final a = AcceptArming();
      expect(a.decide('order-1', inFlightIsLive: false), AcceptDecision.deliver);
      expect(a.decide('order-1', inFlightIsLive: false), AcceptDecision.dropDuplicate);
      expect(a.decide('order-1', inFlightIsLive: true), AcceptDecision.dropDuplicate);
    });

    test('drops a different accept while the in-flight call is LIVE', () {
      // An accidental tap on a second incoming call must not yank someone out
      // of the call they are in.
      final a = AcceptArming();
      expect(a.decide('order-1', inFlightIsLive: false), AcceptDecision.deliver);
      expect(a.decide('order-2', inFlightIsLive: true), AcceptDecision.dropInFlightLive);
      expect(a.inFlightCallId, 'order-1', reason: 'latch must not move');
    });

    test('a different accept SUPERSEDES a latch whose call is not live', () {
      // mitra #435. The black hole: an accept whose call never joined never
      // reports isDisconnected, so callEnded never fires and the latch outlives
      // the call. Every later accept was then dropped for the rest of the
      // process while the SDK — which joins BEFORE the accept callback runs —
      // held camera and mic with no UI. A dead latch must yield.
      final a = AcceptArming();
      expect(a.decide('order-1', inFlightIsLive: false), AcceptDecision.deliver);
      expect(a.decide('order-2', inFlightIsLive: false), AcceptDecision.deliver);
      expect(a.inFlightCallId, 'order-2');
    });

    test('re-arms after the in-flight call ends so the SAME cid rings again',
        () {
      // #5205: a consultation reuses ONE call cid across rings (server T-5,
      // server/mitra T+2 re-ring). The prior latch dropped every accept after
      // the first, so the app never navigated into the rejoined call.
      final a = AcceptArming();
      expect(a.decide('order-1', inFlightIsLive: false), AcceptDecision.deliver);
      a.callEnded('order-1');
      expect(a.hasInFlight, isFalse);
      expect(a.decide('order-1', inFlightIsLive: true), AcceptDecision.deliver,
          reason: 're-ring must deliver');
    });

    test('callEnded for a non-matching id is a no-op', () {
      final a = AcceptArming();
      expect(a.decide('order-1', inFlightIsLive: false), AcceptDecision.deliver);
      a.callEnded('order-2'); // stale subscription from a previous call
      expect(a.hasInFlight, isTrue);
      expect(a.decide('order-1', inFlightIsLive: true), AcceptDecision.dropDuplicate);
    });

    test('reset clears in-flight state', () {
      final a = AcceptArming();
      a.decide('order-1', inFlightIsLive: false);
      a.reset();
      expect(a.hasInFlight, isFalse);
      expect(a.decide('order-1', inFlightIsLive: true), AcceptDecision.deliver);
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

  group('OrphanClaimWatchdog', () {
    // The SDK joins during accept handling, so camera and mic are live before
    // the host can show anything. These are the invariants that decide whether
    // an unclaimed call gets released — the leak this guards against ran 45
    // minutes on a real device.
    const timeout = Duration(seconds: 60);

    OrphanClaimWatchdog watchdog(List<String> released) => OrphanClaimWatchdog(
          onExpired: released.add,
          timeout: timeout,
        );

    test('releases an accept nothing ever claimed', () {
      fakeAsync((async) {
        final released = <String>[];
        watchdog(released).arm('order-1');
        async.elapse(timeout + const Duration(seconds: 1));
        expect(released, ['order-1']);
      });
    });

    test('a claimed accept is never released', () {
      fakeAsync((async) {
        final released = <String>[];
        final w = watchdog(released)..arm('order-1');
        w.disarmIfGuarding('order-1'); // CallSession.joinCall
        expect(w.guardedCallId, isNull);
        async.elapse(timeout * 2);
        expect(released, isEmpty);
      });
    });

    test('releasing a DROPPED accept must not disarm the in-flight guard', () {
      // The id guard. Without it, dropping a second accept stands the watchdog
      // down for the call it was protecting, silently reinstating the leak.
      fakeAsync((async) {
        final released = <String>[];
        final w = watchdog(released)..arm('order-1');
        w.disarmIfGuarding('order-2'); // a different, dropped accept
        expect(w.guardedCallId, 'order-1');
        async.elapse(timeout + const Duration(seconds: 1));
        expect(released, ['order-1']);
      });
    });

    test('fires once, and not at all after the call ends on its own', () {
      fakeAsync((async) {
        final released = <String>[];
        final w = watchdog(released)..arm('order-1');
        async.elapse(timeout + const Duration(seconds: 1));
        expect(released, ['order-1']);
        // Already released: a later disarm/elapse must not fire again.
        w.disarmIfGuarding('order-1');
        async.elapse(timeout * 2);
        expect(released, ['order-1']);
      });
    });

    test('a superseding accept re-points the guard at the new call', () {
      fakeAsync((async) {
        final released = <String>[];
        watchdog(released)
          ..arm('order-1')
          ..arm('order-2');
        async.elapse(timeout + const Duration(seconds: 1));
        expect(released, ['order-2'],
            reason: 'the superseded guard must not fire');
      });
    });

    test('reset cancels a pending release', () {
      fakeAsync((async) {
        final released = <String>[];
        final w = watchdog(released)..arm('order-1');
        w.reset();
        async.elapse(timeout * 2);
        expect(released, isEmpty);
      });
    });

    test('the production timeout is generous enough for a cold-start mount', () {
      // Accept → app boot → consultation load → call screen measured a few
      // seconds on a real device. The timeout only has to bound the leak, so it
      // must stay well clear of a slow-but-legitimate mount: shortening this
      // would leave a call the user was about to see.
      expect(StreamRingService.orphanedAcceptTimeout.inSeconds,
          greaterThanOrEqualTo(30));
    });
  });
}
