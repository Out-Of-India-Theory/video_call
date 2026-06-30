import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/active_call/active_call_controller.dart';
import 'package:oit_video_call/src/active_call/audio_router.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/models/video_user.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../screen/fake_call_session.dart';
import 'fake_audio_router.dart';

void main() {
  // The output-selection rule is the testable heart of the router. The
  // subscription plumbing + `setAudioOutputDevice` calls run against the real
  // WebRTC device notifier and are covered by on-device verification.
  group('selectAudioOutput', () {
    RtcMediaDevice output(String id, {String? groupId}) => RtcMediaDevice(
          id: id,
          label: id,
          groupId: groupId,
          kind: RtcMediaDeviceKind.audioOutput,
        );

    // `groupId` containing "bluetooth" reads as external on every platform
    // (RtcMediaDevice.isExternal), including the test host.
    test('prefers a connected headset over speaker and earpiece', () {
      final selected = selectAudioOutput([
        output('earpiece'),
        output('speaker'),
        output('bt-1', groupId: 'bluetooth-headset'),
      ]);
      expect(selected?.id, 'bt-1');
    });

    test('falls back to loudspeaker when no headset is connected', () {
      final selected = selectAudioOutput([output('earpiece'), output('speaker')]);
      expect(selected?.id, 'speaker');
    });

    test('falls back to the first output when neither headset nor speaker', () {
      final selected = selectAudioOutput([output('earpiece')]);
      expect(selected?.id, 'earpiece');
    });

    test('ignores non-audio-output devices', () {
      final selected = selectAudioOutput([
        const RtcMediaDevice(
          id: 'mic',
          label: 'mic',
          groupId: 'bluetooth-mic',
          kind: RtcMediaDeviceKind.audioInput,
        ),
        output('speaker'),
      ]);
      expect(selected?.id, 'speaker');
    });

    test('returns null when there are no audio outputs', () {
      expect(selectAudioOutput(const []), isNull);
      expect(
        selectAudioOutput([
          const RtcMediaDevice(
            id: 'cam',
            label: 'cam',
            kind: RtcMediaDeviceKind.videoInput,
          ),
        ]),
        isNull,
      );
    });
  });

  group('ActiveCallController audio-router wiring', () {
    late FakeCallSession session;
    late FakeAudioRouter router;
    late ActiveCallController controller;
    late OitVideoCallConfig config;

    setUp(() {
      session = FakeCallSession();
      router = FakeAudioRouter();
      controller = ActiveCallController(session: session, audioRouter: router);
      config = OitVideoCallConfig(
        apiKey: 'k',
        user: const VideoUser(id: 'u', name: 'U'),
        tokenProvider: () async => 't',
      );
    });

    Future<ConnectResult> join() => controller.connectAndJoin(
          config: config,
          callId: 'c1',
          callType: 'default',
          audioOnly: false,
          createIfMissing: false,
        );

    test('attaches the router to the call after a successful join', () async {
      await join();
      expect(router.attached, hasLength(1));
      expect(router.attached.single, same(controller.state.call));
    });

    test(
      'attaches the router when joining directly from a ring accept '
      '(call already active, screen-level join skipped)',
      () async {
        // Accept flow (iOS CallKit / Android FCM) already joined the call, so
        // StreamCallSession.joinCall returns without re-joining — audio
        // routing must still attach on this path.
        session.joinCallNoOp = true;
        await join();
        expect(session.joinCount, 0); // redundant join was skipped...
        expect(
          router.attached.single,
          same(controller.state.call),
        ); // ...but the router attached anyway
      },
    );

    test('detaches the router on endCall', () async {
      await join();
      await controller.endCall();
      expect(router.detachCount, greaterThanOrEqualTo(1));
    });

    test('detaches the router on reset', () async {
      await join();
      controller.reset();
      expect(router.detachCount, greaterThanOrEqualTo(1));
    });

    test('does not attach when the join fails', () async {
      session.joinError = Exception('boom');
      final result = await join();
      expect(result, isA<ConnectErrored>());
      expect(router.attached, isEmpty);
    });
  });
}
