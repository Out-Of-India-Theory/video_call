import 'package:flutter/foundation.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../ring/stream_ring_service.dart';

/// Thrown by [CallSession.getCall] when the backend returns 404 for the
/// requested call id. The screen treats this distinctly from other errors
/// so it can show a "Call not available" message instead of a generic one.
class CallNotFoundError implements Exception {
  const CallNotFoundError();

  @override
  String toString() => 'CallNotFoundError';
}

/// Abstraction over the Stream API surface our screen uses.
///
/// The real implementation wraps `package:stream_video`; the test fake
/// (`FakeCallSession` in `test/screen/`) is used in unit tests so the screen
/// can be driven into success and failure paths without hitting the network.
abstract class CallSession {
  Future<void> connect({
    required String apiKey,
    required User user,
    required String token,
  });

  Future<Call> getCall({required String callType, required String callId});

  /// Like [getCall] but creates the call if it does not exist on the
  /// coordinator. Cannot 404 — first caller creates, subsequent callers
  /// receive the existing call.
  Future<Call> getOrCreateCall({required String callType, required String callId});

  Future<void> joinCall(Call call);

  Future<void> setCameraEnabled(Call call, bool enabled);

  Future<void> leaveCall(Call call);

  /// Ends the call for **all** participants on the Stream coordinator. Use
  /// for "host ends the room" semantics — e.g. an astrologer marking a
  /// consultation complete should drop both their own and the customer's
  /// connections, not just leave the call themselves. Requires the local
  /// user to have `end-call` permission on the call type.
  ///
  /// Throws on failure. Two distinct failure modes:
  ///   * **Invalid call status** (e.g. fastReconnecting): the SDK throws
  ///     *before* running its internal local-leave side-effect. The local
  ///     user is still in the call.
  ///   * **Permission denied / server error**: the SDK has already run
  ///     `_session.leave()` locally and only the server-end-call request
  ///     fails. The local user is already out.
  ///
  /// Callers must be prepared to fall back to [leaveCall] on either —
  /// it's redundant for the second mode but required for the first.
  Future<void> endCallForEveryone(Call call);

  Future<void> dispose();
}

/// Call-level audio policy for a JOINED call.
///
/// The ring-reception [StreamVideo] (see [StreamRingService]) is constructed
/// with [ViewerAudioPolicy] (media playback, `MODE_NORMAL`) so the incoming
/// ringtone plays at full volume instead of being ducked by communication-mode
/// routing. A real call, however, needs [BroadcasterAudioPolicy] (echo
/// cancellation, earpiece/speaker routing, `MODE_IN_COMMUNICATION`). Supplying
/// it as a CALL PREFERENCE makes the per-call PeerConnectionFactory use
/// Broadcaster even when we reuse the Viewer-policy ring connection — call
/// preferences win over the client-level
/// `StreamVideoOptions.audioConfigurationPolicy` (see `Call._ensurePcFactory`).
CallPreferences _callAudioPreferences() => DefaultCallPreferences(
      audioConfigurationPolicy: const BroadcasterAudioPolicy(),
    );

/// Default implementation of [CallSession] that drives the real Stream
/// Video SDK (`stream_video` 1.4.x).
class StreamCallSession implements CallSession {
  @override
  Future<void> connect({
    required String apiKey,
    required User user,
    required String token,
  }) async {
    // When the long-lived ring connection is active, a [StreamVideo] singleton
    // already exists (constructed by StreamRingService at startup). Reuse it —
    // constructing a second one throws (failIfSingletonExists defaults to true)
    // and would drop the push-manager-equipped instance that receives rings.
    if (StreamRingService.instance.isActive) return;
    // Constructing `StreamVideo` installs it as the singleton instance via
    // `_instanceHolder.install`. We only need the side effect; the returned
    // instance is reachable later via `StreamVideo.instance`.
    StreamVideo(apiKey, user: user, userToken: token);
  }

  /// Returns the call already active in this process for [cid], if any — e.g.
  /// one the accept flow (iOS CallKit / Android FCM) joined, or started
  /// joining, before a screen-level join runs. Reusing it avoids the SDK
  /// rejecting a duplicate join with "a call with the same cid is in progress"
  /// and ensures the UI renders the call that is actually connecting.
  Call? _activeCallFor(StreamCallCid cid) {
    for (final active in StreamVideo.instance.state.activeCalls.value) {
      if (active.callCid == cid) return active;
    }
    return null;
  }

  /// The one [Call] instance for [cid] already in play in THIS process, if any:
  /// either an active (joined) call, or the call the ring accept-observer just
  /// accepted and is bringing up ([StreamRingService.acceptedCallFor]).
  ///
  /// Reusing it — instead of minting a fresh [makeCall] — is what prevents a
  /// SECOND SFU session (the "same user joined 2–4× / two participants from one
  /// phone on accept" bug). On accept, the SDK's own accept handler joins the
  /// call it consumed, while this screen-level flow would otherwise join a
  /// DIFFERENT `Call` object for the same cid; the two race `Call.join`'s
  /// `activeCalls` guard (checked before an `await`) and each opens its own
  /// session. Funnelling both onto the SAME instance makes the second join a
  /// no-op (the SDK returns success for an already-connected/-connecting call).
  Call? _reusableCallFor(StreamCallCid cid) =>
      _activeCallFor(cid) ?? StreamRingService.instance.acceptedCallFor(cid);

  @override
  Future<Call> getCall({
    required String callType,
    required String callId,
  }) async {
    final call = StreamVideo.instance.makeCall(
      callType: StreamCallType.fromString(callType),
      id: callId,
      preferences: _callAudioPreferences(),
    );
    final existing = _reusableCallFor(call.callCid);
    if (existing != null) return existing;
    final result = await call.get();
    if (result.isFailure) {
      final failure = result as Failure;
      if (isHttpNotFoundError(failure.error)) {
        throw const CallNotFoundError();
      }
      throw Exception('call.get() failed: ${failure.error}');
    }
    return call;
  }

  @override
  Future<Call> getOrCreateCall({
    required String callType,
    required String callId,
  }) async {
    final call = StreamVideo.instance.makeCall(
      callType: StreamCallType.fromString(callType),
      id: callId,
      preferences: _callAudioPreferences(),
    );
    final existing = _reusableCallFor(call.callCid);
    if (existing != null) return existing;
    final result = await call.getOrCreate();
    if (result.isFailure) {
      final failure = result as Failure;
      throw Exception('call.getOrCreate() failed: ${failure.error}');
    }
    return call;
  }

  @override
  Future<void> joinCall(Call call) async {
    // The accept flow (iOS CallKit / Android FCM) joins the call before this
    // screen-level auto-join runs, so it may already be active. The SDK rejects
    // a second join() on an active cid ("a call with the same cid is in
    // progress") while the in-flight join connects on its own — so skip the
    // redundant join. Paired with getCall/getOrCreateCall returning that active
    // call, the UI renders it as it connects (no spurious "retry" prompt).
    if (_activeCallFor(call.callCid) != null) return;
    // Audio policy for the live call (Broadcaster: echo cancellation +
    // communication-mode routing) is set via the call PREFERENCE in
    // getCall/getOrCreateCall, which wins over the Viewer policy the reused
    // ring-reception SDK was constructed with. See [_callAudioPreferences].
    final result = await call.join();
    if (result.isFailure) {
      final failure = result as Failure;
      // A concurrent join of the same cid was already in flight (typically the
      // ring accept-observer's own `join()` on the call it consumed). The SDK
      // rejects the second attempt with "a call with the same cid is in
      // progress" — but the call IS coming up, so this is a benign reuse, not a
      // failure. Swallowing it (rather than throwing) keeps a single session
      // and avoids stranding the user on the "Joining…"/error screen. Combined
      // with [_reusableCallFor], both paths normally share one instance and
      // never reach here; this is defense-in-depth for the residual race.
      if (isCallAlreadyInProgressError(failure.error)) return;
      throw Exception('call.join() failed: ${failure.error}');
    }
  }

  @override
  Future<void> setCameraEnabled(Call call, bool enabled) async {
    await call.setCameraEnabled(enabled: enabled);
  }

  @override
  Future<void> leaveCall(Call call) async {
    await call.leave();
    // Undo the call's communication-mode audio so in-app media isn't stuck on
    // the earpiece/call-volume path and the next incoming ring plays loud.
    // No-op unless the ring connection is active.
    await StreamRingService.instance.restoreRingAudioPolicy();
  }

  @override
  Future<void> endCallForEveryone(Call call) async {
    final result = await call.end();
    if (result.isFailure) {
      // Permission denied / invalid state. Caller falls back to leaveCall
      // (which restores the ring audio policy on its own).
      final failure = result as Failure;
      throw Exception('call.end() failed: ${failure.error}');
    }
    // Undo communication-mode audio so the next incoming ring plays loud.
    await StreamRingService.instance.restoreRingAudioPolicy();
  }

  @override
  Future<void> dispose() async {
    // Keep the long-lived ring connection alive across individual calls — only
    // StreamRingService.unregister (logout) tears it down. Resetting here would
    // stop the device receiving future rings. The communication-mode audio this
    // call applied is reset back to the loud-ring media policy by
    // [StreamRingService.restoreRingAudioPolicy] on the next ring (and on
    // graceful leave); doing it here would touch native bindings in the
    // SDK-reuse unit tests.
    if (StreamRingService.instance.isActive) return;
    await StreamVideo.reset();
  }
}

/// Detects whether the failure raised by `call.get()` corresponds to an
/// HTTP 404 (call does not exist).
///
/// Implementation note: `stream_video` does not export
/// `VideoErrorWithCause`, so we cannot do a direct `is` check. We rely on
/// the documented field shape — `VideoErrorWithCause.cause` is an
/// `ApiException` whose `code` is the HTTP status — and access it via a
/// `dynamic` cast guarded by try/catch. If a future `stream_video` upgrade
/// changes that contract, this returns `false` instead of misclassifying
/// other failures as 404 — and the unit tests in
/// `test/screen/call_session_test.dart` will fail, surfacing the change.
@visibleForTesting
bool isHttpNotFoundError(Object error) {
  try {
    final cause = (error as dynamic).cause;
    return cause is ApiException && cause.code == 404;
  } catch (_) {
    return false;
  }
}

/// Detects the specific `Call.join()` failure the SDK raises when a join for
/// the same cid is already in flight: `VideoError(message: 'a call with the
/// same cid is in progress')` (stream_video `call.dart`).
///
/// [StreamCallSession.joinCall] treats this as a benign no-op rather than an
/// error — it means another path (typically the ring accept-observer's own
/// `join()`) is already bringing this call up, so failing here would strand the
/// user on the join screen for a call that is actually connecting.
///
/// Like [isHttpNotFoundError], we read `.message` via a `dynamic` cast guarded
/// by try/catch because `stream_video` does not export `VideoError`. A future
/// SDK rewording returns `false` (safe: a real duplicate-join surfaces as a
/// normal error) and the unit tests in `test/screen/call_session_test.dart`
/// flag the change.
@visibleForTesting
bool isCallAlreadyInProgressError(Object error) {
  try {
    final message = (error as dynamic).message;
    return message is String &&
        message.toLowerCase().contains('same cid is in progress');
  } catch (_) {
    return false;
  }
}
