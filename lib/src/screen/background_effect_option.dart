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
        // Render via Stream's CallControlOption so this matches the sibling
        // controls (ToggleCameraOption etc.) — same themed ElevatedButton shape,
        // background, and icon colors. Mirror ToggleCameraOption's enabled/
        // disabled pattern: "on" (blur active) shows the filled icon and the
        // theme's active colors (null => defaults), "off" shows the inactive
        // colors, so blur-on reads the same as camera-on.
        final theme = StreamCallControlsTheme.of(context);
        return CallControlOption(
          icon: Icon(on ? Icons.blur_on : Icons.blur_off),
          iconColor: on ? null : theme.inactiveOptionIconColor,
          backgroundColor: on ? null : theme.inactiveOptionBackgroundColor,
          // Await + guard: applyBlur/clear are platform-channel calls that can
          // throw; without this the rejected Future becomes an unhandled zone
          // error mid-call. On failure we log and leave the toggle as-is (the
          // controller only flips its state when the effect actually applied).
          onPressed: () async {
            try {
              if (on) {
                await effects.clear();
              } else {
                await effects.applyBlur(BlurIntensity.heavy);
              }
            } catch (e, st) {
              debugPrint('[oit_video_call] background blur toggle failed: $e\n$st');
            }
          },
        );
      },
    );
  }
}
