import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/models/video_user.dart';
import 'package:oit_video_call/src/screen/call_screen.dart';
import 'package:oit_video_call/src/screen/permission_gate.dart';

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
  testWidgets('phase 1: temporarily denied → Open Settings (no Retry)', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(granted: false, permanentlyDenied: false);

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('required'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('phase 1: permanently denied → Open Settings (no Retry)', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(granted: false, permanentlyDenied: true);

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate).widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('required'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('phase 1: audioOnly denial message says "Microphone" not "Camera"', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(granted: false, permanentlyDenied: false);

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
}
