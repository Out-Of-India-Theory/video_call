import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/oit_video_call.dart';
import 'package:oit_video_call/src/config.dart';

import '../screen/fake_call_session.dart';

OitVideoCallConfig _config() => OitVideoCallConfig(
      apiKey: 'k',
      user: const VideoUser(id: 'u', name: 'U'),
      tokenProvider: () async => 't',
    );

/// Builds an [ActiveCallController] backed by [FakeCallSession], wires it
/// into the [OitVideoCall] singleton via the test-only injection seam, and
/// flips it into `minimized` mode (with a null `Call`) so the host's overlay
/// is active when we pump but neither the video nor the mic builder reaches
/// a mocked Stream [Call].
ActiveCallController _setupSingletonInMinimized({
  required FakeCallSession session,
  Future<bool> Function(BuildContext)? confirmLeave,
}) {
  final controller = ActiveCallController(session: session);
  OitVideoCall.initForTest(config: _config(), controller: controller);

  // Cache args so the host's `_onEndRequested` can read `confirmLeave`. The
  // returned widget is intentionally unused: only the side effect of
  // populating `lastArgsOrNull` matters here.
  OitVideoCall.callScreen(
    callId: 'c1',
    callType: 'default',
    confirmLeave: confirmLeave,
  );

  // Flip directly into `minimized` without a live Call so the mini's video
  // and mic builders fall into the placeholder branches.
  controller.forceMinimizedForTest(callId: 'c1', callType: 'default');
  expect(controller.state.mode, ActiveCallMode.minimized);
  expect(controller.state.call, isNull);
  return controller;
}

void main() {
  setUp(() async {
    await OitVideoCall.reset();
  });

  testWidgets(
    'mini End cancels when confirmLeave returns false (call NOT ended)',
    (tester) async {
      final session = FakeCallSession();
      var confirmCalls = 0;
      final controller = _setupSingletonInMinimized(
        session: session,
        confirmLeave: (_) async {
          confirmCalls++;
          return false;
        },
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: OitVideoCallHost(child: SizedBox.expand()),
        ),
      );
      await tester.pump();

      final endIcon = find.byIcon(Icons.call_end);
      expect(endIcon, findsOneWidget);

      await tester.tap(endIcon);
      // Allow the awaited `confirmLeave` future to resolve.
      await tester.pump();
      await tester.pump();

      // confirmLeave was consulted but rejected the leave — the controller
      // must still be `minimized` and the session untouched (no leave/dispose).
      expect(confirmCalls, 1);
      expect(controller.state.mode, ActiveCallMode.minimized);
      expect(session.leaveCount, 0);
      expect(session.disposeCount, 0);
    },
  );

  testWidgets(
    'mini End ends the call when confirmLeave returns true',
    (tester) async {
      final session = FakeCallSession();
      var confirmCalls = 0;
      final controller = _setupSingletonInMinimized(
        session: session,
        confirmLeave: (_) async {
          confirmCalls++;
          return true;
        },
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: OitVideoCallHost(child: SizedBox.expand()),
        ),
      );
      await tester.pump();

      final endIcon = find.byIcon(Icons.call_end);
      expect(endIcon, findsOneWidget);

      await tester.tap(endIcon);
      // endCall awaits leave + dispose on the fake session — pump until idle.
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(confirmCalls, 1);
      expect(controller.state.mode, ActiveCallMode.idle);
      // No live Call was ever attached (we flipped straight into minimized
      // via the debug helper) so there is nothing to leave; the session is
      // still disposed.
      expect(session.leaveCount, 0);
      expect(session.disposeCount, 1);
    },
  );

  testWidgets(
    'mini End ends the call directly when no confirmLeave is wired',
    (tester) async {
      final session = FakeCallSession();
      // Pass null to preserve the historical "tap End → call ends" behavior
      // for hosts that haven't opted into a confirmation dialog.
      final controller = _setupSingletonInMinimized(
        session: session,
        confirmLeave: null,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: OitVideoCallHost(child: SizedBox.expand()),
        ),
      );
      await tester.pump();

      final endIcon = find.byIcon(Icons.call_end);
      expect(endIcon, findsOneWidget);

      await tester.tap(endIcon);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(controller.state.mode, ActiveCallMode.idle);
      expect(session.disposeCount, 1);
    },
  );
}
