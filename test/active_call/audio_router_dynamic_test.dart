import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oit_video_call/src/active_call/audio_router.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

class _MockCall extends Mock implements Call {}

/// Drives audio-device changes so a test can simulate a headset connecting /
/// disconnecting mid-call without real hardware.
class _FakeMonitor implements AudioDeviceMonitor {
  _FakeMonitor(this._current);

  List<RtcMediaDevice> _current;
  final StreamController<List<RtcMediaDevice>> _ctrl =
      StreamController<List<RtcMediaDevice>>.broadcast();

  @override
  Stream<List<RtcMediaDevice>> get onDeviceChange => _ctrl.stream;

  @override
  Future<List<RtcMediaDevice>?> currentOutputs() async => _current;

  /// Simulate a plug/unplug/pair event.
  void change(List<RtcMediaDevice> devices) {
    _current = devices;
    _ctrl.add(devices);
  }

  Future<void> dispose() => _ctrl.close();
}

RtcMediaDevice _out(String id, {String? groupId}) => RtcMediaDevice(
      id: id,
      label: id,
      groupId: groupId,
      kind: RtcMediaDeviceKind.audioOutput,
    );

// `groupId` containing "bluetooth" reads as external on every platform
// (including the test host) per RtcMediaDevice.isExternal.
final _speaker = _out('speaker');
final _earpiece = _out('earpiece');
final _bluetooth = _out('bt-1', groupId: 'bluetooth-headset');
final _wired = _out('wired-1', groupId: 'bluetooth-or-headphones'); // external

/// Lets every queued microtask (the device-change delivery + the awaited
/// `setAudioOutputDevice` + the applied-id latch) run to completion.
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  setUpAll(() => registerFallbackValue(_speaker));

  late _MockCall call;
  late _FakeMonitor monitor;
  late StreamAudioRouter router;

  List<String> routedIds() =>
      verify(() => call.setAudioOutputDevice(captureAny()))
          .captured
          .cast<RtcMediaDevice>()
          .map((d) => d.id)
          .toList();

  setUp(() {
    call = _MockCall();
    when(() => call.setAudioOutputDevice(any()))
        .thenAnswer((_) async => const Result.success(none));
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await router.detach();
    await monitor.dispose();
  });

  group('Android (the platform the router actively manages)', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('routes to the loudspeaker when no headset is connected', () async {
      monitor = _FakeMonitor([_speaker, _earpiece]);
      router = StreamAudioRouter(monitor: monitor);

      await router.attach(call);

      expect(routedIds(), ['speaker']);
    });

    test('routes to a Bluetooth headset that connects mid-call', () async {
      monitor = _FakeMonitor([_speaker, _earpiece]);
      router = StreamAudioRouter(monitor: monitor);
      await router.attach(call);

      monitor.change([_speaker, _earpiece, _bluetooth]);
      await settle();

      expect(routedIds(), ['speaker', 'bt-1']);
    });

    test('routes back to the loudspeaker when the headset disconnects',
        () async {
      monitor = _FakeMonitor([_speaker, _earpiece, _bluetooth]);
      router = StreamAudioRouter(monitor: monitor);
      await router.attach(call); // -> bt-1

      monitor.change([_speaker, _earpiece]); // unplug
      await settle();

      expect(routedIds(), ['bt-1', 'speaker']);
    });

    test('follows a wired headset connecting then unplugging', () async {
      monitor = _FakeMonitor([_speaker, _earpiece]);
      router = StreamAudioRouter(monitor: monitor);
      await router.attach(call); // -> speaker

      monitor.change([_speaker, _earpiece, _wired]); // plug wired
      await settle();
      monitor.change([_speaker, _earpiece]); // unplug
      await settle();

      expect(routedIds(), ['speaker', 'wired-1', 'speaker']);
    });

    test('does not re-route when the chosen output is unchanged', () async {
      monitor = _FakeMonitor([_speaker, _earpiece]);
      router = StreamAudioRouter(monitor: monitor);
      await router.attach(call); // -> speaker

      monitor.change([_earpiece, _speaker]); // same outputs, reordered
      await settle();

      expect(routedIds(), ['speaker']); // no second call
    });

    test('retries on the next event when a route change fails transiently',
        () async {
      var attempts = 0;
      when(() => call.setAudioOutputDevice(any())).thenAnswer((_) async {
        attempts++;
        return attempts == 1
            ? Result<None>.error('transient')
            : const Result.success(none);
      });
      monitor = _FakeMonitor([_speaker, _earpiece, _bluetooth]);
      router = StreamAudioRouter(monitor: monitor);
      await router.attach(call); // attempt 1 -> fails, id NOT latched

      monitor.change([_speaker, _earpiece, _bluetooth]); // headset still there
      await settle();

      expect(routedIds(), ['bt-1', 'bt-1']); // retried, not stranded
    });
  });

  group('iOS (routing owned by the OS + SDK)', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('never forces an output — not the speaker, not a connected headset',
        () async {
      monitor = _FakeMonitor([_speaker, _earpiece]);
      router = StreamAudioRouter(monitor: monitor);

      await router.attach(call); // must NOT force speaker on iOS

      monitor.change([_speaker, _earpiece, _bluetooth]); // headset mid-call
      await settle();

      verifyNever(() => call.setAudioOutputDevice(any()));
    });
  });

  test('stops managing output after detach', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    monitor = _FakeMonitor([_speaker, _earpiece]);
    router = StreamAudioRouter(monitor: monitor);
    await router.attach(call); // -> speaker
    await router.detach();

    monitor.change([_speaker, _earpiece, _bluetooth]);
    await settle();

    expect(routedIds(), ['speaker']); // nothing after detach
  });
}
