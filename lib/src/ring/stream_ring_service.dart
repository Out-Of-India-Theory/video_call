import 'dart:async';

import 'package:flutter/foundation.dart';
// Hide the SDK's TokenProvider to avoid clashing with OitVideoCallConfig's
// own typedef of the same name in config.dart.
import 'package:stream_video_flutter/stream_video_flutter.dart'
    hide TokenProvider;
import 'package:stream_video_push_notification/stream_video_push_notification.dart';

import '../config.dart';
import '../models/video_user.dart';
import 'stream_ring_config.dart';

/// Owns a long-lived [StreamVideo] connection used to RECEIVE ringing pushes
/// (server T-5 ring, mitra re-ring) even when the app is backgrounded or
/// killed.
///
/// Unlike the per-call [StreamCallSession] — which constructs and disposes the
/// SDK around a single call — this connection is created ONCE at app startup
/// for eligible users and kept alive so the device stays registered for VoIP
/// (iOS) / FCM (Android) call pushes via the official
/// [StreamVideoPushNotificationManager].
class StreamRingService {
  StreamRingService._();

  /// Process-wide singleton. [StreamCallSession] consults [isActive].
  static final StreamRingService instance = StreamRingService._();

  bool _active = false;

  /// True once [register] has constructed + connected the long-lived SDK.
  ///
  /// [StreamCallSession] reads this to (a) REUSE the connection instead of
  /// constructing a second [StreamVideo] — which would throw because
  /// `failIfSingletonExists` defaults to true — and (b) skip
  /// `StreamVideo.reset` on call end, which would otherwise kill ring
  /// reception.
  bool get isActive => _active;

  /// Test seam for [StreamCallSession] reuse-guard tests.
  @visibleForTesting
  set debugActive(bool value) => _active = value;

  /// Constructs the long-lived [StreamVideo] with the official push manager
  /// and connects (registering the device for call pushes). Idempotent.
  Future<void> register({
    required String apiKey,
    required VideoUser user,
    required TokenProvider tokenProvider,
    required StreamRingProviderNames providerNames,
  }) async {
    if (_active) return;

    StreamVideo(
      apiKey,
      user: User.regular(
        userId: user.id,
        name: user.name,
        image: user.image,
      ),
      tokenLoader: (_) => tokenProvider(),
      pushNotificationManagerProvider:
          StreamVideoPushNotificationManager.create(
        iosPushProvider:
            StreamVideoPushProvider.apn(name: providerNames.apnVoip),
        androidPushProvider:
            StreamVideoPushProvider.firebase(name: providerNames.firebase),
        registerApnDeviceToken: true,
      ),
    );

    final result = await StreamVideo.instance.connect();
    if (result.isFailure) {
      await StreamVideo.reset();
      throw StateError('StreamRingService.register: connect failed ($result)');
    }
    _active = true;
  }

  /// Forwards a background/terminated FCM data message to the SDK so it can
  /// raise the native incoming-call UI. Returns true if the SDK consumed it.
  Future<bool> handleBackgroundFcm(Map<String, dynamic> data) {
    return StreamVideo.instance.handleRingingFlowNotifications(data);
  }

  /// Subscribes to "ring accepted"; the callback receives the accepted [Call].
  StreamSubscription<ActionCallAccept>? observeAccepted(
    void Function(Call call) onAccept,
  ) {
    return StreamVideo.instance
        .observeCallAcceptRingingEvent(onCallAccepted: onAccept);
  }

  /// Tears down the long-lived connection (e.g. on logout).
  Future<void> unregister() async {
    if (!_active) return;
    _active = false;
    await StreamVideo.reset(disconnect: true);
  }
}
