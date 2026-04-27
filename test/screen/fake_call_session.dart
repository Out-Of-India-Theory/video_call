import 'package:mocktail/mocktail.dart';
import 'package:oit_video_call/src/screen/call_session.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// In-memory [CallSession] for unit tests.
///
/// Set the `*Error` / `getCallNotFound` fields before mounting the screen to
/// drive the screen into specific code paths. Counters and `cameraEnabledCalls`
/// are then asserted by the test to verify the lifecycle behavior.
class FakeCallSession implements CallSession {
  // Configurable failure modes. Set before mounting the screen.
  Object? connectError;
  Object? getCallError;

  /// Simulates a 404 from `call.get()` (call does not exist on the
  /// coordinator). Tests check this via [isCallNotFoundError].
  bool getCallNotFound = false;

  Object? joinError;

  // Observable state.
  int connectCount = 0;
  int joinCount = 0;
  int leaveCount = 0;
  int disposeCount = 0;
  final List<bool> cameraEnabledCalls = <bool>[];

  Call? _call;

  @override
  Future<void> connect({
    required String apiKey,
    required User user,
    required String token,
  }) async {
    connectCount++;
    if (connectError != null) throw connectError!;
  }

  @override
  Future<Call> getCall({
    required String callType,
    required String callId,
  }) async {
    if (getCallNotFound) {
      throw const _CallNotFoundError();
    }
    if (getCallError != null) throw getCallError!;
    _call = _FakeCall();
    return _call!;
  }

  @override
  Future<void> joinCall(Call call) async {
    if (joinError != null) throw joinError!;
    joinCount++;
  }

  @override
  Future<void> setCameraEnabled(Call call, bool enabled) async {
    cameraEnabledCalls.add(enabled);
  }

  @override
  Future<void> leaveCall(Call call) async {
    leaveCount++;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

class _CallNotFoundError implements Exception {
  const _CallNotFoundError();

  @override
  String toString() => 'CallNotFound';
}

/// Returns true if [e] is the sentinel error that [FakeCallSession] throws
/// when [FakeCallSession.getCallNotFound] is set.
bool isCallNotFoundError(Object e) => e is _CallNotFoundError;

/// Minimal `Call` sentinel used purely as a typed value passed back to the
/// screen. The screen is not expected to invoke any methods on this object
/// in unit tests; if it does, `noSuchMethod` (via `Mock`) will throw and
/// surface the misuse loudly.
class _FakeCall extends Mock implements Call {}
