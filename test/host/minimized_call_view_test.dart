import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/host/minimized_call_view.dart';

void main() {
  testWidgets(
    'shows Connecting placeholder when no call yet',
    (tester) async {
      // The mini view falls into the `_Placeholder` branch when
      // `controller.state.call` is null. A real, idle controller satisfies
      // that — no need for a placeholder-only constructor or a mocked Call.
      final controller = ActiveCallController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: MinimizedCallView(
              controller: controller,
              onExpand: () {},
              onEnd: () {},
            ),
          ),
        ),
      );
      expect(find.text('Connecting…'), findsOneWidget);
    },
  );
}
