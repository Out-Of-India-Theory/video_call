import 'package:flutter/material.dart';
import 'package:stream_video_filters/video_effects_manager.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../active_call/video_effects_controller.dart';
import '../facade.dart';

/// Control-bar button that toggles background blur on/off (Phase 1).
///
/// A single tap applies heavy background blur; tapping again clears it. Renders
/// nothing when disabled by config or unsupported by the platform, or when no
/// effects controller exists.
///
/// Blur strength is fixed to [BlurIntensity.heavy] — the SDK exposes three
/// discrete levels but product wants a single, strongest-blur toggle. The
/// underlying [VideoEffectsController] still supports all intensities (and the
/// Phase-2 image capability) if a richer picker is wanted later.
class BackgroundEffectOption extends StatelessWidget {
  const BackgroundEffectOption({super.key, required this.call});

  final Call call;

  @override
  Widget build(BuildContext context) {
    if (!OitVideoCall.configOrThrow.enableBackgroundEffects ||
        !VideoEffectsController.isSupportedPlatform) {
      return const SizedBox.shrink();
    }
    final effects = OitVideoCall.controllerOrThrow.effects;
    if (effects == null) return const SizedBox.shrink();

    return ValueListenableBuilder<BackgroundEffect>(
      valueListenable: effects.effect,
      builder: (context, current, _) {
        final on = current != BackgroundEffect.none;
        return IconButton(
          tooltip: on ? 'Turn off blur' : 'Blur background',
          isSelected: on,
          icon: Icon(on ? Icons.blur_on : Icons.blur_off),
          onPressed: () =>
              on ? effects.clear() : effects.applyBlur(BlurIntensity.heavy),
        );
      },
    );
  }
}
