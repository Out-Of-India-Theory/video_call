import 'package:flutter/material.dart';
import 'package:stream_video_filters/video_effects_manager.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../active_call/video_effects_controller.dart';
import '../facade.dart';

/// Control-bar button that opens a sheet to pick a background effect
/// (Phase 1: Off / Blur Light·Medium·Heavy). Renders nothing when disabled by
/// config or unsupported by the platform, or when no effects controller exists.
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
          tooltip: 'Background',
          icon: Icon(on ? Icons.blur_on : Icons.blur_off),
          onPressed: () => _openSheet(context, effects, current),
        );
      },
    );
  }

  Future<void> _openSheet(
    BuildContext context,
    VideoEffectsController effects,
    BackgroundEffect current,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        Widget tile(String label, BackgroundEffect value, VoidCallback apply) {
          return ListTile(
            title: Text(label),
            trailing: current == value ? const Icon(Icons.check) : null,
            onTap: () {
              apply();
              Navigator.of(sheetContext).pop();
            },
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tile('Off', BackgroundEffect.none, effects.clear),
              tile('Blur — Light', BackgroundEffect.blurLight,
                  () => effects.applyBlur(BlurIntensity.light)),
              tile('Blur — Medium', BackgroundEffect.blurMedium,
                  () => effects.applyBlur(BlurIntensity.medium)),
              tile('Blur — Heavy', BackgroundEffect.blurHeavy,
                  () => effects.applyBlur(BlurIntensity.heavy)),
            ],
          ),
        );
      },
    );
  }
}
