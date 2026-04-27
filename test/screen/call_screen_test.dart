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
}
