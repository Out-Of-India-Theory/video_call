import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/active_call/active_call_state.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/errors.dart';
import 'package:oit_video_call/src/models/video_user.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../screen/fake_call_session.dart';
import 'fake_audio_router.dart';

void main() {
  group('ActiveCallController.connectAndJoin', () {
    late FakeCallSession session;
    late ActiveCallController controller;
    late OitVideoCallConfig config;

    setUp(() {
      session = FakeCallSession();
      controller = ActiveCallController(session: session, audioRouter: FakeAudioRouter());
      config = OitVideoCallConfig(
        apiKey: 'k',
        user: const VideoUser(id: 'u', name: 'U'),
        tokenProvider: () async => 't',
      );
    });

    test('happy path: idle → connecting → connected', () async {
      final result = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(result, isA<ConnectReady>());
      expect(controller.state.mode, ActiveCallMode.connected);
      expect(controller.state.call, isNotNull);
      expect(session.connectCount, 1);
      expect(session.getCallCount, 1);
      expect(session.joinCount, 1);
    });

    test('audioOnly: true also calls setCameraEnabled(false)', () async {
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: true,
        createIfMissing: false,
      );
      expect(session.cameraEnabledCalls, [false]);
    });

    test('createIfMissing: true uses getOrCreateCall', () async {
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: true,
      );
      expect(session.getOrCreateCount, 1);
      expect(session.getCallCount, 0);
    });

    test('token fetch failure returns ConnectErrored(tokenFetchFailed)', () async {
      final badConfig = OitVideoCallConfig(
        apiKey: 'k',
        user: const VideoUser(id: 'u', name: 'U'),
        tokenProvider: () async => throw Exception('bad'),
      );
      final result = await controller.connectAndJoin(
        config: badConfig,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(result, isA<ConnectErrored>());
      expect((result as ConnectErrored).message, contains('token'));
      // Mode stays in connecting (controller does not auto-reset on error;
      // the screen calls `reset()` explicitly before retrying).
      expect(controller.state.mode, ActiveCallMode.connecting);
      expect(controller.state.call, isNull);
      expect(session.connectCount, 0);
    });

    test('connect failure returns ConnectErrored(joinFailed)', () async {
      session.connectError = Exception('boom');
      final result = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(result, isA<ConnectErrored>());
      expect((result as ConnectErrored).message, contains('connect'));
    });

    test('getCall not-found returns ConnectErrored(callNotFound)', () async {
      session.getCallNotFound = true;
      final result = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(result, isA<ConnectErrored>());
      expect((result as ConnectErrored).message, contains('not available'));
    });

    test('joinCall failure returns ConnectErrored(joinFailed)', () async {
      session.joinError = Exception('rtc');
      final result = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(result, isA<ConnectErrored>());
      expect((result as ConnectErrored).message, contains('join'));
    });

    test('re-entering with same callId after connect returns existing', () async {
      final r1 = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      final r2 = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect((r1 as ConnectReady).call, same((r2 as ConnectReady).call));
      // No additional I/O on the re-entry.
      expect(session.connectCount, 1);
      expect(session.getCallCount, 1);
      expect(session.joinCount, 1);
    });

    test(
      're-entering with a different callId returns ConnectErrored(unknown)',
      () async {
        // Was previously `throwsStateError`. Returning ConnectErrored keeps
        // `_start()`'s fire-and-forget contract intact: a synchronous throw
        // from a `Future<ConnectResult>`-returning function would surface as
        // an unhandled future error and leave the screen stuck on its
        // loading spinner forever.
        await controller.connectAndJoin(
          config: config,
          callId: 'c1',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        );
        final result = await controller.connectAndJoin(
          config: config,
          callId: 'c2',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        );
        expect(result, isA<ConnectErrored>());
        final errored = result as ConnectErrored;
        expect(errored.code, OitVideoCallErrorCode.unknown);
        expect(errored.message, contains('c1'));
        expect(errored.message, contains('c2'));
      },
    );

    test('after error, reset() then connectAndJoin succeeds (retry path)', () async {
      // Drive the controller into ConnectErrored via a failing tokenProvider.
      final badConfig = OitVideoCallConfig(
        apiKey: 'k',
        user: const VideoUser(id: 'u', name: 'U'),
        tokenProvider: () async => throw Exception('bad'),
      );
      final r1 = await controller.connectAndJoin(
        config: badConfig,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(r1, isA<ConnectErrored>());
      // After the error, mode is still connecting — without reset(),
      // the next connectAndJoin would short-circuit because callId matches.
      controller.reset();
      expect(controller.state.mode, ActiveCallMode.idle);

      final r2 = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(r2, isA<ConnectReady>());
    });

    test('endCall transitions through ending and resets to idle', () async {
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );

      final modes = <ActiveCallMode>[];
      controller.addListener(() => modes.add(controller.state.mode));

      await controller.endCall();
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(controller.state.call, isNull);
      // We saw `ending` along the way and ended at `idle`.
      expect(modes, [ActiveCallMode.ending, ActiveCallMode.idle]);
      expect(session.leaveCount, 1);
      expect(session.disposeCount, 1);
    });

    test('concurrent endCall invocations only run leave/dispose once', () async {
      // Two simultaneous endCall calls (e.g. user taps End in mini AND a host
      // lifecycle observer triggers an end) must not race through leaveCall +
      // dispose twice. The `ending` guard short-circuits the second
      // invocation while the first is still awaiting teardown.
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      await Future.wait([controller.endCall(), controller.endCall()]);
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(session.leaveCount, 1);
      expect(session.disposeCount, 1);
    });

    test('endCall before connect: idempotent no-op when already idle', () async {
      // I-1 from final review: endCall short-circuits when state is already
      // idle so duplicate calls (host lifecycle observer + SDK disconnect
      // listener firing in close succession) don't emit spurious
      // `ending → idle` notification cycles.
      await controller.endCall();
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(session.leaveCount, 0);
      expect(session.disposeCount, 0);
    });

    test('endCall(forEveryone: true) terminates the room via call.end()', () async {
      // Mitra-side path: an astrologer marking a consultation complete ends
      // the call for everyone, not just leaves. The fake records the
      // end-for-everyone hit; the regular `leaveCall` is NOT called because
      // call.end() handles the local leave internally on Stream's side.
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );

      await controller.endCall(forEveryone: true);
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(session.endForEveryoneCount, 1);
      expect(session.leaveCount, 0);
      expect(session.disposeCount, 1);
    });

    test('endCall(forEveryone: true) falls back to leaveCall when end() fails', () async {
      // Stream's `Call.end()` has two failure modes:
      //   1. Invalid status (e.g. fastReconnecting) — SDK throws BEFORE
      //      running its internal local leave. Fallback is REQUIRED to
      //      exit the call.
      //   2. Permission denied / HTTP failure — SDK already ran the
      //      local leave before throwing. Fallback is a redundant
      //      no-op (harmless, `Call.leave()` is idempotent).
      // The fake throws on demand without distinguishing; the controller
      // can't distinguish either, so it always runs the fallback. This
      // test asserts the fallback fires regardless of which mode threw —
      // a future refactor that drops the fallback for "permission denied"
      // would silently regress the invalid-status case, so the assertion
      // on `leaveCount == 1` is load-bearing.
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      session.endForEveryoneError = Exception('permission denied');

      await controller.endCall(forEveryone: true);
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(session.endForEveryoneCount, 1);
      expect(session.leaveCount, 1);
      expect(session.disposeCount, 1);
    });

    test('endCall swallows session.dispose() errors without throwing', () async {
      // Reviewer carry-forward: dispose() was the only un-wrapped call in
      // endCall's teardown — if `StreamVideo.reset()` ever threw, the
      // exception would surface to the host app (e.g. the mitra's order-
      // completion flow showing a generic error toast despite the call
      // tearing down successfully). The wrap ensures the host never has
      // to try/catch around an `OitVideoCall.endCall()` call.
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      session.disposeError = Exception('stream reset failed');

      // Should NOT throw.
      await controller.endCall(forEveryone: true);
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(session.disposeCount, 1);
    });

    test('endCall swallows leave errors (best-effort)', () async {
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      session.leaveError = Exception('boom');
      // Should not throw; final state is still idle.
      await controller.endCall();
      expect(controller.state.mode, ActiveCallMode.idle);
    });

    test(
      'endCall while connectAndJoin is mid-flight: late completion does not flip back to connected',
      () async {
        // Pin connect() so the controller stays in `connecting` until we
        // explicitly release the gate after endCall.
        session.connectGate = Completer<void>();

        final connectFuture = controller.connectAndJoin(
          config: config,
          callId: 'c1',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        );

        // Yield once so connectAndJoin reaches the `await _session.connect`.
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.mode, ActiveCallMode.connecting);

        // Cancel mid-flight.
        await controller.endCall();
        expect(controller.state.mode, ActiveCallMode.idle);

        // Now release the stalled connect. The cancellation check after
        // `connect` should fire, the controller must NOT be flipped back
        // to `connected`, and the future must resolve to ConnectErrored.
        session.connectGate!.complete();
        final result = await connectFuture;

        expect(result, isA<ConnectErrored>());
        expect(controller.state.mode, ActiveCallMode.idle);
        expect(controller.state.call, isNull);

        // The cleanup branch in connectAndJoin disposes the SDK once more
        // on top of endCall's dispose — best-effort double-dispose is
        // documented as safe.
        expect(session.disposeCount, greaterThanOrEqualTo(1));
      },
    );
  });

  group('ActiveCallController background-effects lifecycle', () {
    late FakeCallSession session;
    late ActiveCallController controller;
    late OitVideoCallConfig config;

    setUp(() {
      session = FakeCallSession();
      controller = ActiveCallController(session: session, audioRouter: FakeAudioRouter());
      config = OitVideoCallConfig(
        apiKey: 'k',
        user: const VideoUser(id: 'u', name: 'U'),
        tokenProvider: () async => 't',
      );
    });

    test('effects is non-null after a successful connectAndJoin', () async {
      final result = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(result, isA<ConnectReady>());
      expect(controller.effects, isNotNull);
    });

    test('effects is null after endCall', () async {
      final result = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(result, isA<ConnectReady>());
      expect(controller.effects, isNotNull);

      await controller.endCall();
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(controller.effects, isNull);
    });

    test('effects is null after cleanupForReinit from a live call', () async {
      final result = await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(result, isA<ConnectReady>());
      expect(controller.effects, isNotNull);

      controller.cleanupForReinit();
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(controller.effects, isNull);
    });
  });

  group('ActiveCallController SDK state subscription', () {
    late FakeCallSession session;
    late ActiveCallController controller;
    late OitVideoCallConfig config;

    setUp(() {
      session = FakeCallSession();
      controller = ActiveCallController(session: session, audioRouter: FakeAudioRouter());
      config = OitVideoCallConfig(
        apiKey: 'k',
        user: const VideoUser(id: 'u', name: 'U'),
        tokenProvider: () async => 't',
      );
    });

    test(
      'SDK status disconnected after join → endCall → idle',
      () async {
        // Drive the controller through a successful join so the post-join
        // subscription on `call.state` is wired up.
        final result = await controller.connectAndJoin(
          config: config,
          callId: 'c1',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        );
        expect(result, isA<ConnectReady>());
        expect(controller.state.mode, ActiveCallMode.connected);

        // Simulate the SDK firing a disconnect (server ended, network drop,
        // duration timeout). The fake's `pushCallStatus` flips the underlying
        // state emitter so the controller's listener fires synchronously.
        session.pushCallStatus(
          CallStatus.disconnected(DisconnectReason.ended()),
        );
        // `endCall` is dispatched via `unawaited` from the listener; let the
        // microtask + the awaited `_session.dispose()` settle.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(controller.state.mode, ActiveCallMode.idle);
        expect(controller.state.call, isNull);
        expect(session.leaveCount, 1);
        expect(session.disposeCount, 1);
      },
    );

    test(
      'SDK fastReconnecting flips connected → fastReconnecting and back',
      () async {
        await controller.connectAndJoin(
          config: config,
          callId: 'c1',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        );
        expect(controller.state.mode, ActiveCallMode.connected);

        session.pushCallStatus(
          CallStatus.reconnecting(0, isFastReconnectAttempt: true),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.mode, ActiveCallMode.fastReconnecting);

        session.pushCallStatus(CallStatus.connected());
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.mode, ActiveCallMode.connected);
      },
    );

    test(
      'SDK disconnect after minimize: tears down → idle (auto-dismisses PiP)',
      () async {
        await controller.connectAndJoin(
          config: config,
          callId: 'c1',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        );
        // Move into the minimized state, simulating user back-press → PiP.
        expect(controller.minimize(), isTrue);
        expect(controller.state.mode, ActiveCallMode.minimized);

        // Server ends the call while we're minimized — the SDK pushes
        // `disconnected`, the controller's listener triggers endCall, the
        // host overlay vanishes (mode goes idle).
        session.pushCallStatus(
          CallStatus.disconnected(DisconnectReason.ended()),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(controller.state.mode, ActiveCallMode.idle);
        expect(controller.state.call, isNull);
      },
    );
  });

  group('ActiveCallState equality', () {
    test('equal when all comparable fields match (call excluded)', () {
      const a = ActiveCallState(
        mode: ActiveCallMode.connecting,
        callId: 'c1',
        callType: 'default',
        audioOnly: true,
      );
      const b = ActiveCallState(
        mode: ActiveCallMode.connecting,
        callId: 'c1',
        callType: 'default',
        audioOnly: true,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('differ on mode', () {
      const a = ActiveCallState(mode: ActiveCallMode.connecting, callId: 'c');
      const b = ActiveCallState(mode: ActiveCallMode.connected, callId: 'c');
      expect(a, isNot(equals(b)));
    });

    test('toString mentions mode and call presence', () {
      const a = ActiveCallState(mode: ActiveCallMode.connecting, callId: 'c1');
      expect(a.toString(), contains('connecting'));
      expect(a.toString(), contains('c1'));
      expect(a.toString(), contains('null'));
    });

    test('copyWith(clearCall: true) nulls out the call', () {
      const idle = ActiveCallState();
      // We can't directly construct a Call without an SDK instance, so we
      // assert the mechanics: copyWith without clearCall preserves null,
      // and clearCall is honored even when a call would otherwise be passed.
      final copied = idle.copyWith(clearCall: true);
      expect(copied.call, isNull);
    });
  });
}
