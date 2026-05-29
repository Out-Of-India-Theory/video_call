import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oit_video_call/src/screen/call_screen.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

class _FakeCall extends Mock implements Call {}

void main() {
  test('web control options exclude speakerphone and flip-camera widgets', () {
    final options = webCallControlOptions(call: _FakeCall());

    expect(options, hasLength(2));
    expect(options[0], isA<ToggleCameraOption>());
    expect(options[1], isA<ToggleMicrophoneOption>());
    expect(
      options.whereType<ToggleSpeakerphoneOption>(),
      isEmpty,
      reason: 'speakerphone toggle is mobile-only — its tap no-ops on web',
    );
    expect(
      options.whereType<FlipCameraOption>(),
      isEmpty,
      reason: 'flip-camera is mobile-only — its tap no-ops on web',
    );
  });
}
