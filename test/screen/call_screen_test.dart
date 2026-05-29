import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/active_call/active_call_state.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/models/video_user.dart';
import 'package:oit_video_call/src/screen/call_screen.dart';
import 'package:oit_video_call/src/screen/permission_gate.dart';
import 'package:oit_video_call/src/screen/waiting_banner_gate.dart';

import 'fake_call_session.dart';
import 'fake_permission_gate.dart';

OitVideoCallConfig _config({Future<String> Function()? tokenProvider}) =>
    OitVideoCallConfig(
      apiKey: 'key',
      user: const VideoUser(id: 'u1', name: 'Foo'),
      tokenProvider: tokenProvider ?? (() async => 'jwt'),
    );

/// Swallow render-phase Flutter errors that fire when [CallScreen] reaches
/// its `_Ready` branch under test: that branch builds [StreamCallContainer],
/// which calls into a mocked [Call] and throws "Call ..." / "Mock ..."
/// errors during paint. Restored at teardown.
void _swallowRenderPhaseMockErrors() {
  final priorOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('Call') ||
        details.toString().contains('Mock')) {
      return; // swallow render-phase mock errors
    }
    priorOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = priorOnError);
}

({Widget widget, ActiveCallController controller}) _host({
  required OitVideoCallConfig config,
  required FakeCallSession session,
  required FakePermissionGate gate,
  bool audioOnly = false,
  bool createIfMissing = false,
  Future<bool> Function()? openSettings,
  Future<bool> Function(BuildContext context)? confirmLeave,
}) {
  final controller = ActiveCallController(session: session);
  return (
    widget: MaterialApp(
      home: CallScreen(
        config: config,
        controller: controller,
        callId: 'c1',
        callType: 'default',
        audioOnly: audioOnly,
        createIfMissing: createIfMissing,
        confirmLeave: confirmLeave,
        deps: CallScreenDeps(
          permissionGate: gate,
          openSettings: openSettings,
        ),
      ),
    ),
    controller: controller,
  );
}

void main() {
  testWidgets('phase 1: mic denied → Open Settings (no Retry)', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(
        microphoneGranted: false,
        cameraGranted: false,
      );

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('required'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('phase 1: mic denial in audioOnly mode shows "Microphone" copy', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(
        microphoneGranted: false,
        cameraGranted: false,
      );

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      audioOnly: true,
    ).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('Microphone'), findsOneWidget);
    expect(find.textContaining('Camera'), findsNothing);
  });

  testWidgets('phase 1: mic granted + camera denied → joins audio-only (no error)', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(
        microphoneGranted: true,
        cameraGranted: false,
      );

    _swallowRenderPhaseMockErrors();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    // Don't pumpAndSettle — _Ready triggers StreamCallContainer which would
    // invoke mocked Call methods. Pump enough frames for the phase chain.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // No error screen — best-effort camera doesn't block the join.
    expect(find.text('Open Settings'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    // Camera was requested (host wanted video), the user declined, and we
    // downgraded — connectAndJoin runs setCameraEnabled(false) post-join.
    expect(gate.lastIncludeCamera, true);
    expect(session.joinCount, 1);
    expect(session.cameraEnabledCalls, contains(false));
  });

  testWidgets('audioOnly skips camera permission', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    _swallowRenderPhaseMockErrors();

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      audioOnly: true,
    ).widget);
    // Don't pumpAndSettle — _Ready triggers StreamCallContainer which will
    // invoke mocked Call methods and throw. Pump just enough for the async
    // phase chain to complete.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(gate.lastIncludeCamera, false);
    // Audio-only also means setCameraEnabled(false) post-join
    expect(session.cameraEnabledCalls, contains(false));
  });

  testWidgets('video call requests camera permission', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    _swallowRenderPhaseMockErrors();

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      audioOnly: false,
    ).widget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(gate.lastIncludeCamera, true);
    expect(session.cameraEnabledCalls, isEmpty);
  });

  testWidgets('phase 2: tokenProvider throws → tokenFetchFailed error', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(
      config: _config(tokenProvider: () => Future.error(Exception('500'))),
      session: session,
      gate: gate,
    ).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('token'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('phase 3: session.connect throws → joinFailed', (tester) async {
    final session = FakeCallSession()..connectError = Exception('boom');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('connect'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('phase 4: getCall not found → callNotFound', (tester) async {
    final session = FakeCallSession()..getCallNotFound = true;
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('not available'), findsOneWidget);
  });

  testWidgets('phase 4: getCall throws other error → joinFailed', (tester) async {
    final session = FakeCallSession()..getCallError = Exception('boom');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('load call'), findsOneWidget);
  });

  testWidgets('phase 5: joinCall throws → joinFailed', (tester) async {
    final session = FakeCallSession()..joinError = Exception('rtc fail');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('join'), findsOneWidget);
  });

  testWidgets('happy path: connect + join called once each', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    _swallowRenderPhaseMockErrors();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    // Don't pumpAndSettle — _Ready triggers StreamCallContainer with a Mock Call.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(session.connectCount, 1);
    expect(session.joinCount, 1);
  });

  testWidgets('dispose does NOT leave the call (controller owns lifecycle)', (tester) async {
    // After Task 2, CallScreen's dispose no longer ends the call — the
    // controller owns the lifecycle and outlives the route. The screen only
    // detaches its listener. leaveCall/dispose are now triggered by
    // controller.endCall() (e.g. from OitVideoCall.reset() or, in future
    // tasks, from the host app's "leave" wiring).
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    _swallowRenderPhaseMockErrors();

    final hosted = _host(config: _config(), session: session, gate: gate);
    await tester.pumpWidget(hosted.widget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Now unmount the screen by replacing the widget tree.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(session.leaveCount, 0);
    expect(session.disposeCount, 0);

    // But endCall on the controller does end it — proving the lifecycle is
    // intact, just relocated.
    await hosted.controller.endCall();
    expect(session.leaveCount, 1);
    expect(session.disposeCount, 1);
  });

  testWidgets('Retry re-runs phases', (tester) async {
    final session = FakeCallSession()..connectError = Exception('boom');
    final gate = FakePermissionGate();

    _swallowRenderPhaseMockErrors();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    // First attempt failed at phase 3.
    expect(find.text('Retry'), findsOneWidget);
    expect(session.connectCount, 1);

    // Clear the error and retry.
    session.connectError = null;

    await tester.tap(find.text('Retry'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(session.connectCount, 2);
    expect(session.joinCount, 1);
  });

  testWidgets('createIfMissing: true uses getOrCreateCall, never getCall', (tester) async {
    final session = FakeCallSession();
    // Set getCallNotFound = true to prove getCall is NOT called (otherwise this would fail).
    session.getCallNotFound = true;
    final gate = FakePermissionGate();

    _swallowRenderPhaseMockErrors();

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      createIfMissing: true,
    ).widget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(session.getOrCreateCount, 1);
    expect(session.getCallCount, 0);
    // The screen reaches _Ready (would-be StreamCallContainer rendering); no error UI.
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('createIfMissing: true + getOrCreate failure → joinFailed', (tester) async {
    final session = FakeCallSession()..getOrCreateError = Exception('boom');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      createIfMissing: true,
    ).widget);
    await tester.pumpAndSettle();

    expect(session.getOrCreateCount, 1);
    expect(session.getCallCount, 0);
    expect(find.textContaining('start call'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('createIfMissing: false (default) preserves existing getCall path', (tester) async {
    // Same as the existing 'phase 4: getCall not found → callNotFound' test —
    // this is a regression check that the default path is unchanged.
    final session = FakeCallSession()..getCallNotFound = true;
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('not available'), findsOneWidget);
    expect(session.getOrCreateCount, 0);
  });

  // -----------------------------------------------------------------
  // Task 5: back-press → minimize when connected.
  // -----------------------------------------------------------------

  testWidgets('back press while connected minimizes (no confirm)', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();
    var confirmLeaveCalls = 0;

    _swallowRenderPhaseMockErrors();

    final hosted = _host(
      config: _config(),
      session: session,
      gate: gate,
      confirmLeave: (_) async {
        confirmLeaveCalls++;
        return true;
      },
    );
    await tester.pumpWidget(hosted.widget);
    // Drive the phase chain forward without `pumpAndSettle` (which would
    // block on the StreamCallContainer's mocked Call methods).
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Sanity: controller is connected.
    expect(hosted.controller.state.mode, ActiveCallMode.connected);

    // Act: simulate a system back-press. PopScope intercepts and our
    // handler should call `controller.minimize()` then `_triggerPop()`.
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // The key assertions: minimize ran, confirmLeave did not.
    expect(hosted.controller.state.mode, ActiveCallMode.minimized);
    expect(confirmLeaveCalls, 0);
  });

  testWidgets('back press while connecting calls confirmLeave', (tester) async {
    // Stall connect() so the controller stays in `connecting` mode while
    // we issue the back-press.
    final gate = FakePermissionGate();
    final session = FakeCallSession()..connectGate = Completer<void>();
    var confirmLeaveCalls = 0;

    final hosted = _host(
      config: _config(),
      session: session,
      gate: gate,
      confirmLeave: (_) async {
        confirmLeaveCalls++;
        return false; // user cancels — controller stays connecting.
      },
    );
    await tester.pumpWidget(hosted.widget);
    // Pump enough to clear the permission gate and enter Phase 3 (connect).
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(hosted.controller.state.mode, ActiveCallMode.connecting);

    // Act: back-press while still connecting → confirmLeave should run.
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(confirmLeaveCalls, 1);
    // User cancelled → controller still connecting (not minimized, not idle).
    expect(hosted.controller.state.mode, ActiveCallMode.connecting);

    // Cleanup: release the stalled connect with an error so the connectAndJoin
    // future resolves before the test ends.
    session.connectError = Exception('stop');
    session.connectGate!.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  });

  testWidgets('back press while connecting + confirmed → endCall + idle', (tester) async {
    final gate = FakePermissionGate();
    final session = FakeCallSession()..connectGate = Completer<void>();

    final hosted = _host(
      config: _config(),
      session: session,
      gate: gate,
      confirmLeave: (_) async => true,
    );
    await tester.pumpWidget(hosted.widget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(hosted.controller.state.mode, ActiveCallMode.connecting);

    await tester.binding.handlePopRoute();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Confirmed leave during connecting calls endCall() → controller idle.
    expect(hosted.controller.state.mode, ActiveCallMode.idle);

    // Cleanup: release the stalled connect so the in-flight connectAndJoin
    // resolves. The controller's epoch was bumped by endCall() → the
    // attempt detects cancellation after `connect()` returns and unwinds
    // cleanly without ever flipping to `connected`.
    session.connectGate!.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Sanity: the late completion did not silently flip us back.
    expect(hosted.controller.state.mode, ActiveCallMode.idle);
    expect(hosted.controller.state.call, isNull);
  });

  testWidgets('back press without confirmLeave during connecting does not minimize', (tester) async {
    final gate = FakePermissionGate();
    final session = FakeCallSession()..connectGate = Completer<void>();

    // No confirmLeave wired — the new PopScope wraps regardless. The
    // controller should NOT flip to minimized; it stays connecting (and
    // the route attempts to pop, but the home route has no parent to pop
    // to in the test harness, so we just check the controller state).
    final hosted = _host(
      config: _config(),
      session: session,
      gate: gate,
    );
    await tester.pumpWidget(hosted.widget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(hosted.controller.state.mode, ActiveCallMode.connecting);

    await tester.binding.handlePopRoute();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Connecting + no confirmLeave: PopScope handler calls _triggerPop
    // directly without minimizing. The controller is unchanged (still
    // connecting from the stalled connect()).
    expect(hosted.controller.state.mode, ActiveCallMode.connecting);

    // Cleanup.
    session.connectError = Exception('stop');
    session.connectGate!.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  });

  testWidgets('back press in errored phase does not minimize', (tester) async {
    // Force an error so the screen settles into `_Errored`. Whatever the
    // controller's mode, it is NOT connected/fastReconnecting, so the
    // PopScope handler must NOT call minimize().
    final session = FakeCallSession()..connectError = Exception('boom');
    final gate = FakePermissionGate();

    final hosted = _host(config: _config(), session: session, gate: gate);
    await tester.pumpWidget(hosted.widget);
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    final priorMode = hosted.controller.state.mode;
    expect(priorMode, isNot(ActiveCallMode.connected));
    expect(priorMode, isNot(ActiveCallMode.fastReconnecting));

    await tester.binding.handlePopRoute();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Mode unchanged — the connected/fastReconnecting branch was skipped.
    expect(hosted.controller.state.mode, priorMode);
    expect(hosted.controller.state.mode, isNot(ActiveCallMode.minimized));
  });

  // -----------------------------------------------------------------
  // Task 6: tap minimized → expand. The host pushes a fresh CallScreen
  // (or the app does so via onExpandRequested); when that CallScreen
  // mounts, its `initState` flips the controller back to `connected` so
  // the host's mini overlay disappears in lock-step with the route push.
  // -----------------------------------------------------------------

  testWidgets('initState flips minimized → connected on remount', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    _swallowRenderPhaseMockErrors();

    // Step 1: mount the original screen and connect.
    final hosted = _host(config: _config(), session: session, gate: gate);
    await tester.pumpWidget(hosted.widget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(hosted.controller.state.mode, ActiveCallMode.connected);

    // Step 2: minimize and tear the original screen down (mirrors what
    // happens when the user back-presses while connected).
    expect(hosted.controller.minimize(), isTrue);
    expect(hosted.controller.state.mode, ActiveCallMode.minimized);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    // Controller is still minimized (its mode survives the unmount).
    expect(hosted.controller.state.mode, ActiveCallMode.minimized);

    // Step 3: mount a fresh CallScreen for the same controller — the
    // tap-to-expand path. Its `initState` should flip the controller out
    // of minimized mode without waiting for `connectAndJoin` to resolve.
    await tester.pumpWidget(MaterialApp(
      home: CallScreen(
        config: _config(),
        controller: hosted.controller,
        callId: 'c1',
        callType: 'default',
        audioOnly: false,
        deps: CallScreenDeps(permissionGate: gate),
      ),
    ));
    // No `await tester.pump()` between pumpWidget and the assertion —
    // initState runs synchronously during element mount.
    expect(hosted.controller.state.mode, ActiveCallMode.connected);

    // Drain microtasks so the late `_start()` Future doesn't trip the
    // pending-timer guard at teardown.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  });

  // -----------------------------------------------------------------
  // Waiting-for-other-participant banner: gate-level behavior lives in
  // `waiting_banner_gate_test.dart`. Here we keep one regression test that
  // proves CallScreen does not mount a gate at all when the param is null.
  // -----------------------------------------------------------------

  testWidgets('CallScreen does not mount a banner when waitingForOtherParticipant is null', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();
    _swallowRenderPhaseMockErrors();

    final hosted = _host(config: _config(), session: session, gate: gate);
    await tester.pumpWidget(hosted.widget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(find.byType(WaitingBannerGate), findsNothing);
  });
}
