import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// Keeps a live call's audio output on the most appropriate device for a 1:1
/// video consultation: an external headset (wired or Bluetooth) when one is
/// connected, otherwise the loudspeaker.
///
/// Why this exists: Stream's SDK surfaces audio-device changes but does NOT
/// auto-switch the output route. Without active management, a headset
/// connected mid-call receives no audio, and the stock speakerphone toggle
/// only flips speaker/earpiece — ignoring wired/Bluetooth devices entirely
/// (dharmayana_app#4957). Routing is owned by `ActiveCallController` rather
/// than the call screen so it keeps working while the call is minimized / in
/// PiP, when the screen widget has been disposed.
abstract class AudioRouter {
  /// Starts managing audio output for [call]: applies the correct route once
  /// immediately, then re-applies on every audio-device change until
  /// [detach]. Safe to call repeatedly — it re-attaches to the latest call.
  Future<void> attach(Call call);

  /// Stops managing audio output and releases the device-change listener.
  /// Idempotent.
  Future<void> detach();
}

/// Production [AudioRouter] backed by the real Stream SDK device notifier.
class StreamAudioRouter implements AudioRouter {
  StreamAudioRouter({RtcMediaDeviceNotifier? notifier})
      : _notifierOverride = notifier;

  /// Test seam. When null, the SDK singleton is resolved lazily on first use
  /// (inside [attach]) so merely constructing the router — e.g. in a unit-test
  /// host without the WebRTC plugin — has no native side effects.
  final RtcMediaDeviceNotifier? _notifierOverride;
  RtcMediaDeviceNotifier get _notifier =>
      _notifierOverride ?? RtcMediaDeviceNotifier.instance;

  Call? _call;
  StreamSubscription<List<RtcMediaDevice>>? _deviceSub;

  /// Id of the output device we last selected. Lets us skip redundant
  /// [Call.setAudioOutputDevice] calls (each can cause an audible blip) when a
  /// device-change event doesn't actually change the chosen output.
  String? _appliedDeviceId;

  @override
  Future<void> attach(Call call) async {
    await detach();
    _call = call;
    // Audio routing is best-effort: a host without the WebRTC device notifier
    // (e.g. a unit-test environment) must never break the call, so guard the
    // native access.
    try {
      final notifier = _notifier;
      // `onDeviceChange` only emits on CHANGE, so apply once from the current
      // device list first, then follow subsequent plug/unplug/pair events.
      _deviceSub = notifier.onDeviceChange.listen(
        _applyForDevices,
        onError: (Object _) {}, // ignore device-enumeration errors
      );
      final outputs = (await notifier.audioOutputs()).getDataOrNull();
      if (outputs != null) _applyForDevices(outputs);
    } catch (_) {
      // Swallow — no device management available on this platform/host.
    }
  }

  @override
  Future<void> detach() async {
    final sub = _deviceSub;
    _deviceSub = null;
    _call = null;
    _appliedDeviceId = null;
    // Don't await the cancel: awaiting `StreamSubscription.cancel()` deadlocks
    // a flutter_test `FakeAsync` zone (the same reason `ActiveCallController`
    // unawaits its call-state sub cancel). The listener stops firing
    // synchronously the moment cancel is invoked.
    if (sub != null) unawaited(sub.cancel());
  }

  void _applyForDevices(List<RtcMediaDevice> devices) {
    final call = _call;
    if (call == null) return;
    final target = selectAudioOutput(devices);
    if (target == null || target.id == _appliedDeviceId) return;
    _appliedDeviceId = target.id;
    // Best-effort; if it fails, the next device-change event retries.
    unawaited(call.setAudioOutputDevice(target));
  }
}

/// Chooses the output device for a consultation from [devices]: the first
/// external headset (wired / Bluetooth / headphones) if any is connected, else
/// the loudspeaker, else the first available output. Returns null when there
/// are no audio outputs at all.
///
/// Pure and top-level so it can be unit-tested without the SDK or a live call.
@visibleForTesting
RtcMediaDevice? selectAudioOutput(List<RtcMediaDevice> devices) {
  RtcMediaDevice? speaker;
  RtcMediaDevice? firstOutput;
  for (final device in devices) {
    if (device.kind != RtcMediaDeviceKind.audioOutput) continue;
    firstOutput ??= device;
    if (device.isExternal) return device; // a connected headset wins outright
    if (device.isSpeaker) speaker ??= device;
  }
  return speaker ?? firstOutput;
}
