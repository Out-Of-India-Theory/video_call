import 'dart:async';

import 'package:flutter/foundation.dart';
// Hide the SDK's TokenProvider to avoid clashing with OitVideoCallConfig's
// own typedef of the same name in config.dart.
import 'package:stream_video_flutter/stream_video_flutter.dart'
    hide TokenProvider;
import 'package:stream_video_push_notification/stream_video_push_notification.dart';
// The platform interface isn't re-exported by the package barrel; import it
// directly for the standalone [hasPendingCall] native-call probe.
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

/// Audio policy for the long-lived ring-RECEPTION [StreamVideo].
///
/// Constructing [StreamVideo] applies this policy to the device's GLOBAL audio
/// configuration, and the SDK re-applies the client-level policy during a live
/// call (`setAudioOutputDevice`, connect-time `_applyConnectOptions` in
/// stream_video 1.4.1) — so this policy, not just the per-call preference,
/// governs the live call's routing on iOS.
///
/// - **iOS → [BroadcasterAudioPolicy]** (communication mode, echo cancellation).
///   Incoming rings render via CallKit (system UI), independent of the app's
///   audio session, so Broadcaster does NOT quiet the ring — while it keeps AEC
///   on for the call. Using [ViewerAudioPolicy] here left AEC off and the remote
///   party heard echo whenever an iOS device was in the call (consumer 6.7.5 /
///   mitra 1.8.5).
/// - **Android / other → [ViewerAudioPolicy]** (media playback, `MODE_NORMAL`).
///   Android's communication mode DUCKS the ringtone to near silence, so the
///   ring connection stays on media playback for a loud ring; the live call's
///   audio is fixed per-call by the Broadcaster call preference (which drives
///   the global AudioSwitchManager on Android — Android-to-Android has no echo).
@visibleForTesting
AudioConfigurationPolicy ringReceptionAudioPolicy() =>
    (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
        ? const BroadcasterAudioPolicy()
        : const ViewerAudioPolicy();

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

  /// In-flight [register] guard: a second concurrent [register] returns this
  /// same Future instead of constructing a second [StreamVideo] (which throws,
  /// since `failIfSingletonExists` defaults to true) before `_active` is set.
  Future<void>? _registering;

  /// Accept-handling state (see [wireAcceptHandling]).
  ///
  /// [_acceptSub] is the live "ring accepted" observer, [_consumeTimer] the
  /// cold-start consume poll, and [_acceptWired] an idempotency guard so a
  /// second [wireAcceptHandling] can't install duplicate observers/timers
  /// (which would double-navigate). All are torn down in [unregister].
  StreamSubscription<ActionCallAccept>? _acceptSub;
  Timer? _consumeTimer;
  bool _acceptWired = false;

  /// Per-accept delivery guard. Dedupes the observer + cold-start consume poll
  /// for ONE accept, but RE-ARMS when that call ends so a later ring of the
  /// SAME consultation cid is delivered again (issue #5205). See [AcceptArming].
  final AcceptArming _arming = AcceptArming();

  /// Watches the currently-accepted call so [_arming] can re-arm the moment it
  /// disconnects. Only ever one at a time (a new accept can't be delivered
  /// while one is in flight); torn down in [unregister].
  StreamSubscription<CallState>? _acceptedCallSub;

  /// The call [_arming] is latched on, kept so liveness can be read at decision
  /// time instead of trusting [_acceptedCallSub] to have fired. A call that
  /// never joined never reports `isDisconnected`, so the subscription alone
  /// cannot tell a live session from a dead latch.
  Call? _acceptedCall;

  /// How long an accepted call may go unclaimed by the host before the ring
  /// service leaves it. The SDK joins during accept handling — camera and mic
  /// go live BEFORE [onAccepted] runs — so a host that never shows a call
  /// screen for it (order fetch failed, route errored, screen crashed) would
  /// otherwise leave the hardware held indefinitely with no UI to release it.
  ///
  /// Deliberately far longer than a healthy accept needs, because the two
  /// failures are not symmetric: releasing too late leaves camera and mic held a
  /// while longer, whereas releasing too EARLY hangs up a call the user was
  /// about to be taken into.
  ///
  /// The slow path is longer than it looks. Both host apps hold ring-accept
  /// navigation until home has finished loading, and the consumer's video-call
  /// module is a Play on-demand component that has been seen to stall — so
  /// accept → home-ready → order load → `joinCall` is not bounded by anything
  /// this package controls. Three minutes still turns an unbounded hold (45
  /// minutes was observed) into a bounded one, while making a false release
  /// unlikely enough not to trade one bug for a worse one.
  static const Duration orphanedAcceptTimeout = Duration(seconds: 180);

  /// Bounds how long the accepted call may go unclaimed. Resolves the call from
  /// [_acceptedCall] at expiry rather than capturing it, so a superseding accept
  /// cannot leave a stale closure holding the previous call.
  late final OrphanClaimWatchdog _claimWatchdog = OrphanClaimWatchdog(
    onExpired: (callId) {
      final call = _acceptedCall;
      if (call == null || call.id != callId) return;
      unawaited(_releaseOrphanedCall(call, reason: 'unclaimed by the host'));
    },
  );

  /// Whether the latched call is a real session in progress. Anything short of
  /// joining/joined — idle, incoming, or already disconnected — means the latch
  /// is stale and a different accept may supersede it.
  bool get _inFlightCallIsLive {
    final call = _acceptedCall;
    if (call == null) return false;
    final status = call.state.value.status;
    return status.isAlreadyJoined || status.isJoining || status.isConnecting;
  }

  /// Signals that the host has taken ownership of [callId] — called from
  /// [CallSession.joinCall], i.e. once a call screen is up for it — so the
  /// orphan watchdog stands down.
  void markAcceptClaimed(String callId) =>
      _claimWatchdog.disarmIfGuarding(callId);

  /// Leaves an accepted call the host cannot show, releasing camera and mic.
  /// Returns false if [callId] is not the currently-accepted call.
  ///
  /// For hosts that KNOW they failed — a consultation whose order will not
  /// load, say — this releases immediately instead of waiting out
  /// [orphanedAcceptTimeout].
  /// Refuses once the host has CLAIMED the call, i.e. a call screen is up for
  /// it. Without that guard this leaves whatever call is latched, and a claim
  /// does not clear the latch — so a caller reaching this after a successful
  /// join would hang up a live conversation. Being unclaimed is the whole
  /// premise of "the host cannot show it", so requiring it costs nothing: the
  /// order-failed and screen-gone callers both run before any join.
  Future<bool> leaveAcceptedCall(String callId) async {
    final call = _acceptedCall;
    if (call == null || call.id != callId) return false;
    if (_claimWatchdog.guardedCallId != callId) return false;
    await _releaseOrphanedCall(call, reason: 'host could not show it');
    return true;
  }

  /// Leaves [call] and re-arms accept delivery. Best effort: the point is to
  /// free camera and mic, and a failure here must not throw into ring handling.
  Future<void> _releaseOrphanedCall(Call call, {required String reason}) async {
    _claimWatchdog.disarmIfGuarding(call.id);
    debugPrint('[oit_video_call] leaving orphaned accepted call ${call.id} '
        '($reason) — releasing camera/mic');
    // Re-arm and drop the latch BEFORE leaving. `Call.leave()` only reports
    // `isDisconnected` once teardown FINISHES (stream_video 1.4.x flips the
    // lifecycle after `await _disconnect`), so for the whole teardown window
    // this call still reads as live — and an accept arriving in it would be
    // dropped AND released, which is the exact symptom this method exists to
    // prevent. Safe to do first: `callEnded` is a no-op unless [call] is the
    // latched one, and the id guard below leaves a superseding accept alone.
    _arming.callEnded(call.id);
    if (_acceptedCall?.id == call.id) _acceptedCall = null;
    try {
      await call.leave();
    } catch (e) {
      debugPrint('[oit_video_call] leave of orphaned call ${call.id} '
          'failed: $e');
    }
    // Accepts join under BroadcasterAudioPolicy (communication mode). Undo it,
    // or in-app media stays stuck on the earpiece at call volume and the next
    // ring is ducked — the defect CallSession.leaveCall guards against, and
    // more likely here since the user never got a call screen and goes straight
    // back to browsing. No-op when the ring connection is inactive.
    await restoreRingAudioPolicy();
  }

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
  /// and connects (registering the device for call pushes). Idempotent, and
  /// safe against concurrent calls: a second invocation while the first is
  /// still connecting awaits the same in-flight Future rather than building a
  /// second [StreamVideo] (which would throw before `_active` flips true).
  Future<void> register({
    required String apiKey,
    required VideoUser user,
    required TokenProvider tokenProvider,
    required StreamRingProviderNames providerNames,
  }) async {
    if (_active) return;
    if (_registering != null) return _registering;
    _registering = _doRegister(
      apiKey: apiKey,
      user: user,
      tokenProvider: tokenProvider,
      providerNames: providerNames,
    );
    try {
      await _registering;
    } finally {
      _registering = null;
    }
  }

  Future<void> _doRegister({
    required String apiKey,
    required VideoUser user,
    required TokenProvider tokenProvider,
    required StreamRingProviderNames providerNames,
  }) async {
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
        // Platform-conditional ring-reception audio policy — see
        // [ringReceptionAudioPolicy]. Android uses ViewerAudioPolicy (media,
        // MODE_NORMAL) so communication-mode routing doesn't DUCK the ringtone
        // to near silence; iOS uses BroadcasterAudioPolicy (its ring is CallKit,
        // unaffected by this policy) to keep echo cancellation on for the live
        // call and avoid the remote-echo regression.
        audioConfigurationPolicy: ringReceptionAudioPolicy(),
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

  /// Restores the ring-reception audio configuration (see
  /// [ringReceptionAudioPolicy]) after a call.
  ///
  /// On Android a live call switches the device into communication mode
  /// ([BroadcasterAudioPolicy]) for echo cancellation and earpiece routing.
  /// Because the ring connection is kept alive across calls (we never
  /// `StreamVideo.reset` while ringing is active), that communication mode would
  /// otherwise linger and DUCK the next incoming ring — so this resets Android
  /// to media playback ([ViewerAudioPolicy]). Call this on call teardown and
  /// before showing a ring. (On iOS the ring is CallKit, so the policy stays
  /// Broadcaster — a no-op change.) No-op when ringing isn't active in this
  /// isolate; best-effort (a failure only degrades ring loudness).
  Future<void> restoreRingAudioPolicy() async {
    if (!_active) return;
    try {
      await RtcMediaDeviceNotifier.instance
          .reinitializeAudioConfiguration(ringReceptionAudioPolicy());
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
      // Platform-conditional ring-reception policy (see
      // [ringReceptionAudioPolicy] / register): Android media playback so this
      // background ring-reception SDK doesn't duck the ringtone; iOS Broadcaster
      // (its ring is CallKit) to keep echo cancellation on for the live call.
      options: StreamVideoOptions(
        audioConfigurationPolicy: ringReceptionAudioPolicy(),
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
        // Treat a ring as video unless the payload EXPLICITLY disables it
        // (matches the SDK's showIncomingCall default, and iOS requires a
        // video ring to foreground the app on accept).
        hasVideo: data['video'] != 'false',
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
    // Idempotency: a second wireAcceptHandling must not install a second
    // observer/timer, or an accept would deliver twice → double-navigate.
    if (_acceptWired) return;
    _acceptWired = true;

    // Accept the call under the Broadcaster audio policy (communication mode,
    // AEC/earpiece). The long-lived ring connection runs under
    // ViewerAudioPolicy (media, no AEC) so the ring plays at full volume; an
    // accepted-from-ring call must override that per-call or it would join with
    // the wrong audio routing. See register() / call_session.dart.
    final acceptPrefs = DefaultCallPreferences(
      audioConfigurationPolicy: const BroadcasterAudioPolicy(),
    );

    void deliver(Call call) {
      // Dedupes the two delivery mechanisms (observer + consume poll) for ONE
      // accept. Unlike the prior process-lifetime latch, [AcceptArming] RE-ARMS
      // when the accepted call ends, so a later ring of the SAME consultation
      // cid (server T-5/T+2 re-ring, mitra "Ring customer") navigates again
      // instead of being silently dropped (#5205).
      switch (_arming.decide(call.id, inFlightIsLive: _inFlightCallIsLive)) {
        case AcceptDecision.dropDuplicate:
          // The same accept reported twice; the host already has this call.
          // Nothing to release — leaving would hang up the live session.
          return;
        case AcceptDecision.dropInFlightLive:
          // A DIFFERENT call, dropped to avoid yanking the user out of the one
          // they are in. The SDK joins BEFORE this callback runs, so leave it or
          // camera and mic stay held with no UI to release them.
          unawaited(_releaseOrphanedCall(call, reason: 'accept dropped'));
          return;
        case AcceptDecision.deliver:
          break;
      }
      _watchAcceptedCallEnd(call);
      _claimWatchdog.arm(call.id);
      onAccepted(call.id);
    }

    _acceptSub = StreamVideo.instance.observeCallAcceptRingingEvent(
      onCallAccepted: deliver,
      acceptCallPreferences: acceptPrefs,
    );

    // Cold-start: an Accept tap that launched the app leaves an already-accepted
    // CallKit call to consume — but it may NOT be consumable the instant we
    // register (the app is still booting and the SDK still connecting), so a
    // single consumeAndAcceptActiveCall can miss it (lands on home, no nav).
    // Poll until the accepted call surfaces (or a bounded timeout).
    void tryConsume() {
      // Bail once an accept is in flight or the service has been unregistered:
      // after unregister() calls StreamVideo.reset() the synchronous
      // StreamVideo.instance getter THROWS, and `.catchError` only guards the
      // returned Future, not that sync access — so guard it explicitly.
      if (_arming.hasInFlight || !_active) return;
      try {
        unawaited(
          StreamVideo.instance
              .consumeAndAcceptActiveCall(
                onCallAccepted: deliver,
                callPreferences: acceptPrefs,
              )
              .catchError((Object _) => false),
        );
      } catch (_) {}
    }

    tryConsume();
    var attempts = 1;
    _consumeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      attempts++;
      if (_arming.hasInFlight || attempts > 12) {
        t.cancel();
        return;
      }
      tryConsume();
    });
  }

  /// Watches the accepted [call] and re-arms [_arming] the moment it
  /// disconnects, so the next ring of the same cid is delivered again. Replaces
  /// any prior watch (only one accept is ever in flight).
  void _watchAcceptedCallEnd(Call call) {
    _acceptedCallSub?.cancel();
    _acceptedCall = call;
    _acceptedCallSub = watchCallEnd(call, () {
      _arming.callEnded(call.id);
      _acceptedCallSub = null;
      if (_acceptedCall?.id == call.id) _acceptedCall = null;
      // The call ended on its own; nothing left to watch for a claim.
      _claimWatchdog.disarmIfGuarding(call.id);
    });
  }

  /// Subscribes to [call]'s state and invokes [onEnded] exactly once — the
  /// first time the call reports `isDisconnected` — then cancels the
  /// subscription.
  ///
  /// Extracted + [visibleForTesting] so the re-arm wiring ([_watchAcceptedCallEnd])
  /// is covered without the [StreamVideo] singleton: the #5205 fix hinges on
  /// this listener firing once at call end. `isDisconnected` is the same
  /// call-ended signal [ActiveCallController] keys off; transient
  /// connecting/reconnecting states don't match (no false re-arm mid-call), and
  /// the call is never disconnected at subscribe time (it was just accepted),
  /// so the self-cancel only runs on a later async event.
  @visibleForTesting
  static StreamSubscription<CallState> watchCallEnd(
    Call call,
    void Function() onEnded,
  ) {
    late final StreamSubscription<CallState> sub;
    sub = call.state.listen((state) {
      if (!state.status.isDisconnected) return;
      onEnded();
      unawaited(sub.cancel());
    });
    return sub;
  }

  /// Tears down the long-lived connection (e.g. on logout).
  Future<void> unregister({String? fcmToken}) async {
    if (!_active) return;
    _active = false;
    // Delete this device's push token(s) from Stream BEFORE reset, so a
    // logged-out device stops receiving rings for the old user.
    // `reset(disconnect: true)` only drops the socket — it leaves the device
    // REGISTERED on Stream (the cause of the logged-out-device-still-rings bug).
    // Best-effort: never let cleanup failures block logout.
    try {
      // iOS VoIP + APN tokens (the push manager knows them). On Android this is
      // a no-op (getDevicePushTokenVoIP returns "" there).
      await StreamVideo.instance.pushNotificationManager?.unregisterDevice();
    } catch (e) {
      debugPrint('StreamRingService.unregister: unregisterDevice failed: $e');
    }
    if (fcmToken != null && fcmToken.isNotEmpty) {
      // Android FCM token — NOT covered by unregisterDevice (which deletes
      // VoIP/APN only). The host app supplies it (the SDK can't read it: the
      // plugin's StreamTokenProvider is hidden from its exports).
      try {
        await StreamVideo.instance.removeDevice(pushToken: fcmToken);
      } catch (e) {
        debugPrint('StreamRingService.unregister: removeDevice(fcm) failed: $e');
      }
    }
    // Tear down accept handling BEFORE reset: a still-running consume poll
    // would otherwise hit StreamVideo.instance after reset wipes the singleton.
    _consumeTimer?.cancel();
    _consumeTimer = null;
    await _acceptSub?.cancel();
    _acceptSub = null;
    await _acceptedCallSub?.cancel();
    _acceptedCallSub = null;
    _acceptedCall = null;
    _claimWatchdog.reset();
    _arming.reset();
    _acceptWired = false;
    await StreamVideo.reset(disconnect: true);
  }
}

/// What to do with an incoming accept, per [AcceptArming.decide].
///
/// Reported rather than inferred because the two drop reasons need OPPOSITE
/// handling of the joined call: a duplicate must be left alone (it is the live
/// session the host already has), while a different call must be left, or its
/// camera and mic stay held with no UI. Deriving that from the latched id would
/// silently pick wrong the moment a third reason is added.
enum AcceptDecision {
  /// Hand this accept to the host; it is now latched.
  deliver,

  /// A duplicate report of the accept already in flight.
  dropDuplicate,

  /// A different call, dropped because the in-flight one is genuinely live.
  dropInFlightLive,
}

/// Bounds how long an accepted call may go unclaimed by the host.
///
/// Accept handling joins the call BEFORE the host is told, so camera and mic are
/// live before anything can show a call screen. If nothing ever claims the call
/// this fires so the session can be left. Pure + synchronous (the release action
/// is a callback) so the invariants are testable without the `StreamVideo`
/// singleton — including the id guard in [disarmIfGuarding], which is the part
/// that silently reinstates the leak if a refactor drops it.
@visibleForTesting
class OrphanClaimWatchdog {
  OrphanClaimWatchdog({
    required this.onExpired,
    this.timeout = StreamRingService.orphanedAcceptTimeout,
  });

  /// Invoked with the guarded call id when [timeout] elapses unclaimed.
  final void Function(String callId) onExpired;

  final Duration timeout;

  String? _guardedCallId;
  Timer? _timer;

  /// The call currently guarded, or null when standing down.
  String? get guardedCallId => _guardedCallId;

  /// Starts guarding [callId], replacing any previous guard.
  void arm(String callId) {
    _timer?.cancel();
    _guardedCallId = callId;
    _timer = Timer(timeout, () {
      _timer = null;
      if (_guardedCallId != callId) return;
      _guardedCallId = null;
      onExpired(callId);
    });
  }

  /// Stands down — but ONLY when guarding [callId]. Releasing a *dropped* accept
  /// must not disarm the watchdog protecting the in-flight call, or an orphaned
  /// call would go unreleased and hold camera and mic indefinitely.
  void disarmIfGuarding(String callId) {
    if (_guardedCallId != callId) return;
    _guardedCallId = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Full stand-down (teardown / unregister).
  void reset() {
    _guardedCallId = null;
    _timer?.cancel();
    _timer = null;
  }
}

/// Decides whether an incoming "ring accepted" should be delivered to the host
/// app (which navigates into the call).
///
/// Two SDK mechanisms can report the SAME accept — the live
/// `observeCallAcceptRingingEvent` observer and the cold-start
/// `consumeAndAcceptActiveCall` poll — so a "deliver once" guard is needed to
/// avoid double-navigation. Crucially that guard must RE-ARM when the accepted
/// call ends: a consultation reuses ONE call cid (`default:<orderId>`) across
/// rings (server T-5, server/mitra T+2 re-ring), so a process-lifetime latch
/// dropped every accept after the first and the app never navigated into the
/// rejoined call (issue #5205). Pure + synchronous so it is unit-testable
/// without the `StreamVideo` singleton.
@visibleForTesting
class AcceptArming {
  String? _inFlightCallId;

  /// True while an accept has been delivered but its call hasn't ended yet.
  bool get hasInFlight => _inFlightCallId != null;

  /// The latched call id, if any. Used for logging; the delivery decision comes
  /// from [decide], which reports its reason rather than making callers infer it
  /// from this.
  String? get inFlightCallId => _inFlightCallId;

  /// Decides what to do with an accept for [callId], latching it when delivered.
  ///
  /// Drops a duplicate report of the in-flight accept — the live observer and
  /// the cold-start consume poll can both report ONE accept — and drops a
  /// *different* accept while the in-flight call is still live
  /// ([inFlightIsLive]), so an accidental tap on a second incoming call cannot
  /// yank someone out of the call they are in.
  ///
  /// A different accept DOES supersede a latch whose call is no longer live.
  /// Without that the latch was a black hole: [callEnded] is driven by the call
  /// reporting `isDisconnected`, which a call that never *joined* never does —
  /// its state stays idle and it receives no updates, not even for a
  /// server-side end. One accept whose join failed therefore silenced every
  /// later accept for the rest of the process, while the SDK — which joins
  /// BEFORE the accept callback runs — held camera and mic with no UI to
  /// release them (mitra #435).
  AcceptDecision decide(String callId, {required bool inFlightIsLive}) {
    if (_inFlightCallId == null) {
      _inFlightCallId = callId;
      return AcceptDecision.deliver;
    }
    if (_inFlightCallId == callId) return AcceptDecision.dropDuplicate;
    if (inFlightIsLive) return AcceptDecision.dropInFlightLive;
    _inFlightCallId = callId;
    return AcceptDecision.deliver;
  }

  /// Re-arms once the in-flight call ends so a later ring of the same cid is
  /// delivered again. No-op for a stale/mismatched id.
  void callEnded(String callId) {
    if (_inFlightCallId == callId) _inFlightCallId = null;
  }

  /// Full reset (teardown / unregister).
  void reset() => _inFlightCallId = null;
}
