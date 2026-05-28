import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/oit_video_call.dart';
import 'package:oit_video_call/src/config.dart';

void main() {
  setUp(() async {
    await OitVideoCall.reset();
  });

  testWidgets('callScreen before init shows notInitialized error', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OitVideoCall.callScreen(callId: 'c1'),
    ));
    await tester.pump();

    expect(find.textContaining('not initialized', findRichText: true), findsOneWidget);
  });

  testWidgets('callScreen() caches waitingForOtherParticipant on lastArgsOrNull', (tester) async {
    OitVideoCall.initForTest(
      config: OitVideoCallConfig(
        apiKey: 'k',
        user: const VideoUser(id: 'u', name: 'Foo'),
        tokenProvider: () async => 'jwt',
      ),
      controller: ActiveCallController(),
    );
    const banner = SizedBox(key: ValueKey('banner'));
    await tester.pumpWidget(MaterialApp(
      home: OitVideoCall.callScreen(
        callId: 'c1',
        waitingForOtherParticipant: banner,
      ),
    ));
    expect(OitVideoCall.lastArgsOrNull?.waitingForOtherParticipant, same(banner));
  });
}
