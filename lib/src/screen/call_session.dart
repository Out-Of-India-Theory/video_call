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

/// Default implementation of [CallSession] that drives the real Stream
/// Video SDK (`stream_video` 1.3.x).
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

  @override
  Future<Call> getCall({
    required String callType,
    required String callId,
  }) async {
    final call = StreamVideo.instance.makeCall(
      callType: StreamCallType.fromString(callType),
      id: callId,
    );
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
    );
    final result = await call.getOrCreate();
    if (result.isFailure) {
      final failure = result as Failure;
      throw Exception('call.getOrCreate() failed: ${failure.error}');
    }
    return call;
  }

  @override
  Future<void> joinCall(Call call) async {
    final result = await call.join();
    if (result.isFailure) {
      final failure = result as Failure;
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
  }

  @override
  Future<void> endCallForEveryone(Call call) async {
    final result = await call.end();
    if (result.isFailure) {
      // Permission denied / invalid state. Caller falls back to leaveCall.
      final failure = result as Failure;
      throw Exception('call.end() failed: ${failure.error}');
    }
  }

  @override
  Future<void> dispose() async {
    // Keep the long-lived ring connection alive across individual calls — only
    // StreamRingService.unregister (logout) tears it down. Resetting here would
    // stop the device receiving future rings.
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
