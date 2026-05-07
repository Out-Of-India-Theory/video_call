import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/host/minimized_call_view.dart';

void main() {
  testWidgets(
    'shows Connecting placeholder when no remote participant',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Material(
            child: MinimizedCallView.placeholderForTest(),
          ),
        ),
      );
      expect(find.text('Connecting…'), findsOneWidget);
    },
  );
}
