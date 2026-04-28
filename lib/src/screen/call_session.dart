import 'package:flutter/foundation.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

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

  Future<void> joinCall(Call call);

  Future<void> setCameraEnabled(Call call, bool enabled);

  Future<void> leaveCall(Call call);

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
  Future<void> dispose() async {
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
