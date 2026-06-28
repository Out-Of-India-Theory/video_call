import 'dart:async';

import 'package:flutter/foundation.dart';
// Hide the SDK's TokenProvider to avoid clashing with OitVideoCallConfig's
// own typedef of the same name in config.dart.
import 'package:stream_video_flutter/stream_video_flutter.dart'
    hide TokenProvider;
import 'package:stream_video_push_notification/stream_video_push_notification.dart';
// The platform interface isn't re-exported by the package barrel; import it
// directly for the standalone [hasPendingAcceptedCall] native-call probe.
import 'package:stream_video_push_notification/stream_video_push_notification_platform_interface.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models/video_user.dart';
import 'stream_ring_config.dart';

/// Incoming-call notification config: a loud system ringtone played as a CALL
/// (ring stream, not the quiet notification stream) + full-screen on the lock
/// screen. Without this the ring is barely audible and shows as a plain banner.
const StreamVideoPushConfiguration _ringPushConfig = StreamVideoPushConfiguration(
  android: AndroidPushConfiguration(
    ringtonePath: 'system_ringtone_default',
    incomingCallNotificationChannelName: 'Incoming Consultations',
    showFullScreenOnLockScreen: true,
  ),
);

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
      // Keep the long-lived ring connection alive when backgrounded so a
      // backgrounded (not killed) app receives rings over the existing socket
      // instead of a cold reconnect (per Stream docs).
      options: StreamVideoOptions(
        keepConnectionsAliveWhenInBackground: true,
        // CRITICAL for ring loudness: constructing StreamVideo immediately
        // calls reinitializeAudioConfiguration(policy). The default
        // BroadcasterAudioPolicy sets the device to MODE_IN_COMMUNICATION
        // (voice-call routing), which DUCKS the incoming-call ringtone
        // (USAGE_NOTIFICATION_RINGTONE on STREAM_RING) to near silence — even
        // at max ring volume. A ring-RECEPTION connection is not a live call,
        // so use ViewerAudioPolicy (media playback, MODE_NORMAL): the ring
        // plays at full volume. The actual joined call (OitVideoCall.init)
        // keeps the default Broadcaster policy for proper call audio.
        audioConfigurationPolicy: const ViewerAudioPolicy(),
      ),
      tokenLoader: (_) => tokenProvider(),
      pushNotificationManagerProvider:
          StreamVideoPushNotificationManager.create(
        iosPushProvider:
            StreamVideoPushProvider.apn(name: providerNames.apnVoip),
        androidPushProvider:
            StreamVideoPushProvider.firebase(name: providerNames.firebase),
        registerApnDeviceToken: true,
        pushConfiguration: _ringPushConfig,
      ),
    );

    final result = await StreamVideo.instance.connect();
    if (result.isFailure) {
      await StreamVideo.reset();
      throw StateError('StreamRingService.register: connect failed ($result)');
    }
    _active = true;
  }

  /// Forwards a FOREGROUND FCM data message to the live SDK so it can raise the
  /// native incoming-call UI. Requires [StreamVideo.instance] to already exist
  /// (i.e. ring registration ran in this isolate). For the background/terminated
  /// isolate use [handleBackgroundPush] instead.
  Future<bool> handleBackgroundFcm(Map<String, dynamic> data) async {
    // A previous call may have left the device in communication mode, which
    // would duck this ring to near silence. Restore the loud-ring media policy
    // before raising the incoming-call UI.
    await restoreRingAudioPolicy();
    return StreamVideo.instance.handleRingingFlowNotifications(data);
  }

  /// Restores the loud-ring audio configuration ([ViewerAudioPolicy], media
  /// playback / `MODE_NORMAL`).
  ///
  /// A live call switches the device into communication mode
  /// ([BroadcasterAudioPolicy]) for echo cancellation and earpiece routing.
  /// Because the ring connection is kept alive across calls (we never
  /// `StreamVideo.reset` while ringing is active), that communication mode would
  /// otherwise linger and DUCK the next incoming ring. Call this on call
  /// teardown and before showing a ring. No-op when ringing isn't active in this
  /// isolate; best-effort (a failure only degrades ring loudness).
  Future<void> restoreRingAudioPolicy() async {
    if (!_active) return;
    try {
      await RtcMediaDeviceNotifier.instance
          .reinitializeAudioConfiguration(const ViewerAudioPolicy());
    } catch (e) {
      debugPrint('StreamRingService: restoring ring audio policy failed: $e');
    }
  }

  /// Canonical terminated/background-isolate ring handler (per Stream docs).
  ///
  /// A fresh FCM background isolate has NO [StreamVideo.instance], so we
  /// CREATE a standalone instance (with the push manager), connect it, observe
  /// the core ringing events, arrange disposal after the ring resolves, then
  /// hand the payload to the SDK which raises the native incoming-call UI.
  ///
  /// Callers (the app's `@pragma('vm:entry-point')` FCM handler) must supply
  /// everything from persisted storage, since `F.*`/Riverpod are unavailable in
  /// the background isolate.
  Future<bool> handleBackgroundPush({
    required String apiKey,
    required VideoUser user,
    required TokenProvider tokenProvider,
    required StreamRingProviderNames providerNames,
    required Map<String, dynamic> data,
  }) async {
    if (data['sender'] != 'stream.video') return false;

    // Fire-and-forget connect (cascade `..connect()`) per Stream docs — do NOT
    // `await` it: a cold-start connect can take several seconds, and awaiting it
    // would block the incoming-call display below until it completes (causing
    // the ring to auto-cancel before CallKit ever shows).
    final sv = StreamVideo.create(
      apiKey,
      user: User.regular(userId: user.id, name: user.name, image: user.image),
      // ViewerAudioPolicy (media, MODE_NORMAL) so constructing this background
      // ring-reception SDK does NOT switch the device into communication mode,
      // which would duck the incoming-call ringtone. See register() for detail.
      options: StreamVideoOptions(
        audioConfigurationPolicy: const ViewerAudioPolicy(),
      ),
      tokenLoader: (_) => tokenProvider(),
      pushNotificationManagerProvider:
          StreamVideoPushNotificationManager.create(
        iosPushProvider:
            StreamVideoPushProvider.apn(name: providerNames.apnVoip),
        androidPushProvider:
            StreamVideoPushProvider.firebase(name: providerNames.firebase),
        registerApnDeviceToken: true,
        pushConfiguration: _ringPushConfig,
      ),
    )..connect();

    // Observe incoming/declined ring events, and dispose the standalone SDK
    // once the ring is resolved (accept/decline/timeout/ended).
    final sub = sv.observeCoreRingingEventsForBackground();
    sv.disposeAfterResolvingRinging(disposingCallback: sub.dispose);

    final type = data['type'] as String?;
    final callCid = data['call_cid'] as String?;
    final manager = sv.pushNotificationManager;

    // INSTANT SHOW: for a ring, raise the native incoming-call UI immediately
    // from the push payload — no network / getCallRingingState round-trip. In an
    // OS-throttled FCM background isolate the coordinator connect can take ~30s,
    // so gating the display on it (as handleRingingFlowNotifications does) makes
    // the ring miss its own window. The `..connect()` + observers above still
    // run so Accept can join the call.
    if (type == 'call.ring' && callCid != null && manager != null) {
      final displayName = data['call_display_name'] as String?;
      final createdByName = data['created_by_display_name'] as String?;
      await manager.showIncomingCall(
        uuid: const Uuid().v4(),
        callCid: callCid,
        callerName: (displayName != null && displayName.isNotEmpty)
            ? displayName
            : createdByName,
        handle: data['created_by_id'] as String?,
        hasVideo: data['video'] == 'true',
      );
      return true;
    }

    // Missed calls (and anything else) go through the standard handler.
    return sv.handleRingingFlowNotifications(data);
  }

  /// Subscribes to "ring accepted"; the callback receives the accepted [Call].
  StreamSubscription<ActionCallAccept>? observeAccepted(
    void Function(Call call) onAccept,
  ) {
    return StreamVideo.instance
        .observeCallAcceptRingingEvent(onCallAccepted: onAccept);
  }

  /// Whether the native incoming-call layer (CallKit on iOS,
  /// ConnectionService on Android) currently holds ANY call — the signal that
  /// the app may have been cold-started / woken by an incoming ring and should
  /// register the ring service NOW to consume + join it.
  ///
  /// Deliberately checks `isNotEmpty`, NOT a per-call `isAccepted` flag: this
  /// mirrors the SDK's own cold-start handling
  /// ([StreamVideoPushNotificationManager] keys off
  /// `activeCalls().isNotEmpty`), and on iOS the native `isAccepted` flag lags
  /// the cold launch — it isn't yet true the instant the app boots, so gating
  /// on it misses the call. Once the ring service is registered, its Accept
  /// handling (`observeCallAcceptRingingEvent` + the polled
  /// `consumeAndAcceptActiveCall`, which DOES filter `isAccepted`) catches the
  /// accept as soon as the flag flips.
  ///
  /// Reads the native call list directly through the push-notification platform
  /// channel (the same source [StreamVideo.consumeAndAcceptActiveCall] uses),
  /// so it works at the very start of app launch WITHOUT a constructed
  /// [StreamVideo] / live ring connection — and WITHOUT downloading the
  /// on-demand video module. Best-effort: any failure (plugin not yet
  /// registered, off-mobile, malformed payload) yields false.
  Future<bool> hasPendingCall() async {
    try {
      final raw =
          await StreamVideoPushNotificationPlatform.instance.activeCalls();
      return raw is List && raw.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Wires Accept handling so the app can navigate into the call when the user
  /// accepts the incoming ring. Covers BOTH states:
  ///  - app alive when Accept is tapped → [observeCallAcceptRingingEvent]
  ///  - app cold-started by tapping Accept → [consumeAndAcceptActiveCall]
  /// The SDK consumes + joins the call; [onAccepted] receives its call id so the
  /// host app can show the call screen. Requires [register] to have run.
  void wireAcceptHandling(void Function(String callId) onAccepted) {
    var handled = false;
    void deliver(Call call) {
      if (handled) return;
      handled = true;
      onAccepted(call.id);
    }

    StreamVideo.instance.observeCallAcceptRingingEvent(onCallAccepted: deliver);

    // Cold-start: an Accept tap that launched the app leaves an already-accepted
    // CallKit call to consume — but it may NOT be consumable the instant we
    // register (the app is still booting and the SDK still connecting), so a
    // single consumeAndAcceptActiveCall can miss it (lands on home, no nav).
    // Poll until the accepted call surfaces (or a bounded timeout).
    void tryConsume() {
      if (handled) return;
      unawaited(
        StreamVideo.instance
            .consumeAndAcceptActiveCall(onCallAccepted: deliver)
            .catchError((Object _) => false),
      );
    }

    tryConsume();
    var attempts = 1;
    Timer.periodic(const Duration(seconds: 1), (t) {
      attempts++;
      if (handled || attempts > 12) {
        t.cancel();
        return;
      }
      tryConsume();
    });
  }

  /// Tears down the long-lived connection (e.g. on logout).
  Future<void> unregister() async {
    if (!_active) return;
    _active = false;
    await StreamVideo.reset(disconnect: true);
  }
}
