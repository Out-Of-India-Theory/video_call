import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

Widget _host({
  required OitVideoCallConfig config,
  required FakeCallSession session,
  required FakePermissionGate gate,
  bool audioOnly = false,
  Future<bool> Function()? openSettings,
}) {
  return MaterialApp(
    home: CallScreen(
      config: config,
      callId: 'c1',
      callType: 'default',
      audioOnly: audioOnly,
      deps: CallScreenDeps(
        session: session,
        permissionGate: gate,
        openSettings: openSettings,
      ),
    ),
  );
}

void main() {
  testWidgets('phase 1: permissions temporarily denied → Retry shown', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(granted: false, permanentlyDenied: false);

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('required'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open Settings'), findsNothing);
  });

  testWidgets('phase 1: permanently denied → Open Settings shown', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(granted: false, permanentlyDenied: true);

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('permanently'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('audioOnly skips camera permission', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    final priorOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('Call') ||
          details.toString().contains('Mock')) {
        return; // swallow render-phase mock errors
      }
      priorOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = priorOnError);

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      audioOnly: true,
    ));
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

    final priorOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('Call') ||
          details.toString().contains('Mock')) {
        return; // swallow render-phase mock errors
      }
      priorOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = priorOnError);

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      audioOnly: false,
    ));
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
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('token'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('phase 3: session.connect throws → joinFailed', (tester) async {
    final session = FakeCallSession()..connectError = Exception('boom');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('connect'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('phase 4: getCall not found → callNotFound', (tester) async {
    final session = FakeCallSession()..getCallNotFound = true;
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('not available'), findsOneWidget);
  });

  testWidgets('phase 4: getCall throws other error → joinFailed', (tester) async {
    final session = FakeCallSession()..getCallError = Exception('boom');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('load call'), findsOneWidget);
  });

  testWidgets('phase 5: joinCall throws → joinFailed', (tester) async {
    final session = FakeCallSession()..joinError = Exception('rtc fail');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('join'), findsOneWidget);
  });

  testWidgets('happy path: connect + join called once each', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    final priorOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('Call') ||
          details.toString().contains('Mock')) {
        return; // swallow render-phase mock errors
      }
      priorOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = priorOnError);

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    // Don't pumpAndSettle — _Ready triggers StreamCallContainer with a Mock Call.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(session.connectCount, 1);
    expect(session.joinCount, 1);
  });
}
