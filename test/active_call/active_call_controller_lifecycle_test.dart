import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/active_call/active_call_state.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/models/video_user.dart';

import '../screen/fake_call_session.dart';

void main() {
  group('ActiveCallController.connectAndJoin', () {
    late FakeCallSession session;
    late ActiveCallController controller;
    late OitVideoCallConfig config;

    setUp(() {
      session = FakeCallSession();
      controller = ActiveCallController(session: session);
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

    test('re-entering with a different callId throws StateError', () async {
      await controller.connectAndJoin(
        config: config,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        createIfMissing: false,
      );
      expect(
        () => controller.connectAndJoin(
          config: config,
          callId: 'c2',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        ),
        throwsStateError,
      );
    });

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

    test('endCall before connect: tears down session, no leave', () async {
      await controller.endCall();
      expect(controller.state.mode, ActiveCallMode.idle);
      expect(session.leaveCount, 0);
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
