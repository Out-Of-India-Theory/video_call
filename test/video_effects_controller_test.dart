import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/video_effects_controller.dart';

void main() {
  test('effect enum defaults to none as first value', () {
    expect(BackgroundEffect.values.first, BackgroundEffect.none);
  });

  test('isSupportedPlatform is a pure getter (does not throw)', () {
    expect(() => VideoEffectsController.isSupportedPlatform, returnsNormally);
  });
}
