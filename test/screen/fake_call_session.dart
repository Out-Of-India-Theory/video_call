import 'dart:async';

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

  /// When non-null, [connect] awaits this completer before returning. Lets a
  /// test pin the controller in `connecting` mode while it pumps a back-press.
  Completer<void>? connectGate;

  /// Simulates a 404 from `call.get()` (call does not exist on the
  /// coordinator). Throws the same [CallNotFoundError] the real session
  /// would throw, so the screen exercises the same `on CallNotFoundError`
  /// branch in production and tests.
  bool getCallNotFound = false;

  Object? getOrCreateError;

  Object? joinError;
  Object? leaveError;

  // Observable state.
  int connectCount = 0;
  int getCallCount = 0;
  int getOrCreateCount = 0;
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
    if (connectGate != null) await connectGate!.future;
    if (connectError != null) throw connectError!;
  }

  @override
  Future<Call> getCall({
    required String callType,
    required String callId,
  }) async {
    getCallCount++;
    if (getCallNotFound) {
      throw const CallNotFoundError();
    }
    if (getCallError != null) throw getCallError!;
    _call = _FakeCall();
    return _call!;
  }

  @override
  Future<Call> getOrCreateCall({
    required String callType,
    required String callId,
  }) async {
    getOrCreateCount++;
    if (getOrCreateError != null) throw getOrCreateError!;
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
    if (leaveError != null) throw leaveError!;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

/// Minimal `Call` sentinel used purely as a typed value passed back to the
/// screen. The screen is not expected to invoke any methods on this object
/// in unit tests; if it does, `noSuchMethod` (via `Mock`) will throw and
/// surface the misuse loudly.
class _FakeCall extends Mock implements Call {}
