import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/active_call/active_call_state.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/facade.dart';
import 'package:oit_video_call/src/models/video_user.dart';

import 'screen/fake_call_session.dart';

OitVideoCallConfig _testConfig() => OitVideoCallConfig(
      apiKey: 'k',
      user: const VideoUser(id: 'u', name: 'U'),
      tokenProvider: () async => 't',
    );

void main() {
  setUp(() async {
    // Ensure a clean slate between tests.
    await OitVideoCall.reset();
  });

  group('OitVideoCall lifecycle', () {
    test('isInitialized is false before init', () {
      expect(OitVideoCall.isInitialized, isFalse);
    });

    test('isInitialized becomes true after init', () {
      OitVideoCall.init(
        apiKey: 'key',
        user: const VideoUser(id: 'u1', name: 'Foo'),
        tokenProvider: () async => 'jwt',
      );
      expect(OitVideoCall.isInitialized, isTrue);
    });

    test('reset clears initialization', () async {
      OitVideoCall.init(
        apiKey: 'key',
        user: const VideoUser(id: 'u1', name: 'Foo'),
        tokenProvider: () async => 'jwt',
      );
      await OitVideoCall.reset();
      expect(OitVideoCall.isInitialized, isFalse);
    });

    test('init can be called twice (idempotent replace)', () {
      OitVideoCall.init(
        apiKey: 'k1',
        user: const VideoUser(id: 'u1', name: 'A'),
        tokenProvider: () async => 't1',
      );
      OitVideoCall.init(
        apiKey: 'k2',
        user: const VideoUser(id: 'u2', name: 'B'),
        tokenProvider: () async => 't2',
      );
      expect(OitVideoCall.isInitialized, isTrue);
    });

    test(
      're-initing cleans up the previous controller synchronously',
      () async {
        // Reviewer-asked load-bearing assertion: the cleanup must complete
        // its sync prefix BEFORE `init`/`initForTest` returns, otherwise
        // the new controller's `connectAndJoin` would race Stream's
        // singleton-already-installed check (`_session.connect` constructs
        // `StreamVideo`, which throws if the previous controller's
        // `_session.dispose()` hasn't reset the singleton yet). The fix
        // routes through `ActiveCallController.cleanupForReinit()`, which
        // calls `_session.dispose()` synchronously — `StreamVideo.reset()`
        // clears its singleton via `InstanceHolder.reset()` (sync, just
        // `_instance = null`) before the returned `Future` even matters.
        final sessionA = FakeCallSession();
        final controllerA = ActiveCallController(session: sessionA);
        OitVideoCall.initForTest(
          config: _testConfig(),
          controller: controllerA,
        );

        // Drive A into a state where it has a live Call + subscription.
        final r1 = await controllerA.connectAndJoin(
          config: _testConfig(),
          callId: 'c1',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        );
        expect(r1, isA<ConnectReady>());
        expect(controllerA.state.call, isNotNull);

        // Re-init with a new controller. The cleanup must be synchronous —
        // no pump / no microtask drain.
        final sessionB = FakeCallSession();
        OitVideoCall.initForTest(
          config: _testConfig(),
          controller: ActiveCallController(session: sessionB),
        );

        // Assertions hold IMMEDIATELY — proves cleanup is synchronous.
        expect(
          controllerA.state.mode,
          ActiveCallMode.idle,
          reason: 'old controller must be idle by the time init returns '
              '— the _callStateSub it held is cancelled here',
        );
        expect(
          sessionA.disposeCount,
          1,
          reason: 'old session.dispose() must run synchronously inside '
              'cleanupForReinit so StreamVideo.reset() clears the SDK '
              'singleton before init returns; otherwise the new '
              'controller\'s connectAndJoin would race the install check',
        );
        expect(
          sessionA.leaveCount,
          1,
          reason: 'old session.leaveCall() also kicks off synchronously '
              '(its sync prefix runs); network round-trip to Stream\'s '
              'coordinator is best-effort and fire-and-forget',
        );
        // The new controller is untouched.
        expect(sessionB.leaveCount, 0);
        expect(sessionB.disposeCount, 0);
      },
    );
  });
}
