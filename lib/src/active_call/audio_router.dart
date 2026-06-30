import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// Keeps a live call's audio output on the most appropriate device for a 1:1
/// video consultation. On every non-iOS-native target (**Android**, and web
/// via `setSinkId`) it follows a connected external headset (wired or
/// Bluetooth) and otherwise routes to the loudspeaker. On **native iOS** the OS
/// and SDK already own routing, so the router intentionally does not force an
/// output there (see the platform guard in [StreamAudioRouter._applyForDevices]).
///
/// Why this exists: on Android the SDK surfaces audio-device changes but does
/// NOT auto-switch the output route, so a headset connected mid-call receives
/// no audio, and the stock speakerphone toggle only flips speaker/earpiece —
/// ignoring wired/Bluetooth devices entirely (dharmayana_app#4957). Routing is
/// owned by `ActiveCallController` rather than the call screen so it keeps
/// working while the call is minimized / in PiP, when the screen widget has
/// been disposed.
abstract class AudioRouter {
  /// Starts managing audio output for [call]: applies the correct route once
  /// immediately, then re-applies on every audio-device change until
  /// [detach]. Safe to call repeatedly — it re-attaches to the latest call.
  Future<void> attach(Call call);

  /// Stops managing audio output and releases the device-change listener.
  /// Idempotent.
  Future<void> detach();
}

/// Source of audio-output device state. Wraps the SDK's
/// [RtcMediaDeviceNotifier] in production; a fake in tests drives
/// connect/disconnect events deterministically.
@visibleForTesting
abstract class AudioDeviceMonitor {
  /// Emits the full device list on every plug/unplug/pair change.
  Stream<List<RtcMediaDevice>> get onDeviceChange;

  /// The current output devices, or null when enumeration is unavailable.
  Future<List<RtcMediaDevice>?> currentOutputs();
}

class _RtcDeviceMonitor implements AudioDeviceMonitor {
  _RtcDeviceMonitor(this._notifier);

  final RtcMediaDeviceNotifier _notifier;

  @override
  Stream<List<RtcMediaDevice>> get onDeviceChange => _notifier.onDeviceChange;

  @override
  Future<List<RtcMediaDevice>?> currentOutputs() async =>
      (await _notifier.audioOutputs()).getDataOrNull();
}

/// Production [AudioRouter] backed by the real Stream SDK device notifier.
class StreamAudioRouter implements AudioRouter {
  StreamAudioRouter({@visibleForTesting AudioDeviceMonitor? monitor})
      : _monitorOverride = monitor;

  /// Test seam. When null, the SDK device notifier is resolved lazily on first
  /// use (inside [attach]) so merely constructing the router — e.g. in a
  /// unit-test host without the WebRTC plugin — has no native side effects.
  final AudioDeviceMonitor? _monitorOverride;
  AudioDeviceMonitor get _monitor =>
      _monitorOverride ?? _RtcDeviceMonitor(RtcMediaDeviceNotifier.instance);

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
      final monitor = _monitor;
      // `onDeviceChange` only emits on CHANGE, so apply once from the current
      // device list first, then follow subsequent plug/unplug/pair events.
      _deviceSub = monitor.onDeviceChange.listen(
        _applyForDevices,
        onError: (Object e) =>
            debugPrint('[oit_video_call] AudioRouter.onDeviceChange error: $e'),
      );
      final outputs = await monitor.currentOutputs();
      if (outputs != null) await _applyForDevices(outputs);
    } catch (e, st) {
      // Best-effort: a host without the WebRTC device notifier (e.g. a
      // unit-test environment) must never break the call.
      debugPrint('[oit_video_call] AudioRouter.attach failed: $e\n$st');
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

  Future<void> _applyForDevices(List<RtcMediaDevice> devices) async {
    final call = _call;
    if (call == null) return;
    final target = selectAudioOutput(devices);
    if (target == null || target.id == _appliedDeviceId) return;
    // The router forces output on every non-iOS-native target (Android, and
    // web via `setSinkId`), where the OS does NOT auto-switch on a mid-call
    // device change. Only NATIVE iOS is skipped — there routing is owned by the
    // OS + SDK:
    //   * external (wired/BT): iOS auto-routes, and the SDK deliberately does
    //     not force it — `Call._applyDefaultAudioOutput` nulls the default
    //     output for an iOS external device ("trust the OS to set it as
    //     default" — stream_video 1.4.1 call.dart:2480);
    //   * loudspeaker for a video call: the SDK sets `speakerDefaultOn` at join.
    // Forcing `setAudioOutputDevice` on iOS re-runs `setAppleAudioConfiguration`
    // with the CLIENT-level `audioConfigurationPolicy` (rtc_manager.dart:1374) —
    // which is `ViewerAudioPolicy` on a ring-registered connection — re-applying
    // the wrong AVAudioSession mode to a live call. The `!kIsWeb` keeps this
    // skip off web (an iPhone Safari reports `iOS` but uses the harmless
    // `setSinkId` path, not `setAppleAudioConfiguration`).
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return;
    }
    final result = await call.setAudioOutputDevice(target);
    if (result.isFailure) {
      // Leave `_appliedDeviceId` unset so the next device-change event retries.
      // A transient failure while a headset is mid-negotiation must not strand
      // the route permanently (that would re-create dharmayana_app#4957).
      debugPrint(
        '[oit_video_call] AudioRouter.setAudioOutputDevice(${target.id}) '
        'failed: ${(result as Failure).error}',
      );
      return;
    }
    _appliedDeviceId = target.id;
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
