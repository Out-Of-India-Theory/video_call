import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:stream_video_filters/video_effects_manager.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// The active background effect on the local video track (Phase 1: blur only).
enum BackgroundEffect { none, blurLight, blurMedium, blurHeavy }

/// Owns a [StreamVideoEffectsManager] for the live [Call] and exposes a small,
/// app-facing API for background blur. One instance per active call: created by
/// [ActiveCallController] on connect and [dispose]d on teardown.
///
/// Image backgrounds ([applyImage]) are exposed as a capability for Phase 2 but
/// are not wired to any Phase-1 UI.
class VideoEffectsController {
  VideoEffectsController(Call call)
      : _manager = StreamVideoEffectsManager(call);

  final StreamVideoEffectsManager _manager;

  /// Current effect, so the control can reflect the active selection.
  final ValueNotifier<BackgroundEffect> effect =
      ValueNotifier<BackgroundEffect>(BackgroundEffect.none);

  /// Whether background filters can run on this device. iOS supports them only
  /// on 15+; Android (our minSdk 21+) is always capable; web is unsupported.
  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    if (Platform.isIOS) {
      final match =
          RegExp(r'(\d+)').firstMatch(Platform.operatingSystemVersion);
      final major = match == null ? 0 : int.parse(match.group(1)!);
      return major >= 15;
    }
    return Platform.isAndroid;
  }

  bool _disposed = false;

  Future<void> applyBlur(BlurIntensity intensity) async {
    if (_disposed) return;
    await _manager.applyBackgroundBlurFilter(intensity);
    if (_disposed) return;
    effect.value = switch (intensity) {
      BlurIntensity.light => BackgroundEffect.blurLight,
      BlurIntensity.medium => BackgroundEffect.blurMedium,
      BlurIntensity.heavy => BackgroundEffect.blurHeavy,
    };
  }

  /// Phase-2 capability (preset/custom images). Not used by Phase-1 UI.
  Future<void> applyImage(String assetOrUrl) async {
    if (_disposed) return;
    await _manager.applyBackgroundImageFilter(assetOrUrl);
  }

  Future<void> clear() async {
    if (_disposed) return;
    await _manager.disableAllFilters();
    if (_disposed) return;
    effect.value = BackgroundEffect.none;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _manager.dispose();
    effect.dispose();
  }
}
