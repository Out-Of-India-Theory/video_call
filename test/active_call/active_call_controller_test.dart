import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/active_call/active_call_state.dart';

void main() {
  group('ActiveCallController', () {
    test('starts idle', () {
      final c = ActiveCallController();
      expect(c.state.mode, ActiveCallMode.idle);
      expect(c.state.callId, isNull);
    });

    test('beginConnecting transitions idle → connecting', () {
      final c = ActiveCallController();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.beginConnecting(callId: 'abc', callType: 'default', audioOnly: false);

      expect(c.state.mode, ActiveCallMode.connecting);
      expect(c.state.callId, 'abc');
      expect(c.state.audioOnly, false);
      expect(notifications, 1);
    });

    test('minimize() is rejected when not connected', () {
      final c = ActiveCallController();
      c.beginConnecting(callId: 'abc', callType: 'default', audioOnly: false);
      expect(c.minimize(), isFalse);
      expect(c.state.mode, ActiveCallMode.connecting);
    });

    test('reset() returns to idle and clears callId', () {
      final c = ActiveCallController();
      c.beginConnecting(callId: 'abc', callType: 'default', audioOnly: false);
      c.reset();
      expect(c.state.mode, ActiveCallMode.idle);
      expect(c.state.callId, isNull);
    });

    test('rejects beginConnecting when not idle', () {
      final c = ActiveCallController();
      c.beginConnecting(callId: 'abc', callType: 'default', audioOnly: false);
      expect(
        () => c.beginConnecting(
          callId: 'def',
          callType: 'default',
          audioOnly: false,
        ),
        throwsStateError,
      );
    });
  });
}
