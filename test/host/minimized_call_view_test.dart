import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/host/minimized_call_view.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

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

  group('pickMinimizedParticipant', () {
    test('empty: returns null', () {
      expect(pickMinimizedParticipant(const []), isNull);
    });

    test('solo (only local): returns local so the tile is not blank', () {
      final local = _participant(userId: 'u1', isLocal: true);
      expect(pickMinimizedParticipant([local]), same(local));
    });

    test('1:1 nobody speaking: returns the remote', () {
      final local = _participant(userId: 'u1', isLocal: true);
      final remote = _participant(userId: 'u2', isLocal: false);
      expect(pickMinimizedParticipant([local, remote]), same(remote));
    });

    test('1:1 local is dominant: still returns remote (peer stays visible)',
        () {
      // Regression guard for PR #5 review feedback: the consultation tile
      // must not flip to self-view when the local user is talking.
      final local = _participant(
        userId: 'u1',
        isLocal: true,
        isDominantSpeaker: true,
      );
      final remote = _participant(userId: 'u2', isLocal: false);
      expect(pickMinimizedParticipant([local, remote]), same(remote));
    });

    test('1:1 remote is dominant: returns the dominant remote', () {
      final local = _participant(userId: 'u1', isLocal: true);
      final remote = _participant(
        userId: 'u2',
        isLocal: false,
        isDominantSpeaker: true,
      );
      expect(pickMinimizedParticipant([local, remote]), same(remote));
    });

    test('multi-party: dominant remote wins over non-dominant remotes', () {
      final local = _participant(userId: 'u1', isLocal: true);
      final remoteA = _participant(userId: 'u2', isLocal: false);
      final remoteB = _participant(
        userId: 'u3',
        isLocal: false,
        isDominantSpeaker: true,
      );
      expect(
        pickMinimizedParticipant([local, remoteA, remoteB]),
        same(remoteB),
      );
    });

    test('multi-party: local-dominant ignored, falls back to first remote',
        () {
      final local = _participant(
        userId: 'u1',
        isLocal: true,
        isDominantSpeaker: true,
      );
      final remoteA = _participant(userId: 'u2', isLocal: false);
      final remoteB = _participant(userId: 'u3', isLocal: false);
      expect(
        pickMinimizedParticipant([local, remoteA, remoteB]),
        same(remoteA),
      );
    });
  });
}

CallParticipantState _participant({
  required String userId,
  bool isLocal = false,
  bool isDominantSpeaker = false,
}) {
  return CallParticipantState(
    userId: userId,
    roles: const [],
    name: userId,
    custom: const {},
    sessionId: 's-$userId',
    trackIdPrefix: 'tp-$userId',
    isLocal: isLocal,
    isDominantSpeaker: isDominantSpeaker,
  );
}
