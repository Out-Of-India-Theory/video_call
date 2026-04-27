import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/oit_video_call.dart';

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
}
