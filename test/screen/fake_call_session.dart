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

  /// When true, [joinCall] returns without joining — models the accept flow
  /// (CallKit / FCM) where the SDK already joined the call before the
  /// screen-level join runs, so the real session skips the redundant join.
  bool joinCallNoOp = false;

  Object? leaveError;

  // Observable state.
  int connectCount = 0;
  int getCallCount = 0;
  int getOrCreateCount = 0;
  int joinCount = 0;
  int leaveCount = 0;
  int endForEveryoneCount = 0;
  Object? endForEveryoneError;
  int disposeCount = 0;
  Object? disposeError;
  final List<bool> cameraEnabledCalls = <bool>[];

  _FakeCall? _call;

  /// Pushes a synthetic [CallState] update through the emitter behind the
  /// most-recently-issued fake [Call]. Tests use this to drive
  /// `ActiveCallController._onSdkCallStateChanged` (e.g. simulating a server
  /// disconnect or a fast-reconnect transition) without standing up a real
  /// SDK connection.
  ///
  /// No-op if [getCall] / [getOrCreateCall] hasn't issued a call yet — that
  /// matches the production reality (no call → no state to emit).
  void pushCallStatus(CallStatus status) {
    final call = _call;
    if (call == null) return;
    final current = call.state.value;
    call.stateNotifier.value = current.copyWith(status: status);
  }

  /// Pushes a synthetic [CallState] update that swaps the participant list.
  /// Used by call-screen tests to drive the waiting-banner gate.
  void pushParticipants(List<CallParticipantState> participants) {
    final call = _call;
    if (call == null) return;
    final current = call.state.value;
    call.stateNotifier.value = current.copyWith(callParticipants: participants);
  }

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
    if (joinCallNoOp) return;
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
  Future<void> endCallForEveryone(Call call) async {
    endForEveryoneCount++;
    if (endForEveryoneError != null) throw endForEveryoneError!;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (disposeError != null) throw disposeError!;
  }
}

/// Minimal `Call` sentinel used purely as a typed value passed back to the
/// screen. Most members route through `noSuchMethod` (via `Mock`) so that
/// any inadvertent SDK call surfaces loudly as a test failure. We override
/// [state] (and expose [stateNotifier] for tests to push synthetic updates)
/// because [ActiveCallController] subscribes to it after a successful join
/// to react to natural disconnects and reconnect transitions.
class _FakeCall extends Mock implements Call {
  _FakeCall()
      : stateNotifier = _FakeStateEmitter<CallState>(
          CallState(
            currentUserId: 'u',
            callCid: StreamCallCid(cid: 'default:c1'),
            preferences: DefaultCallPreferences(),
          ),
        );

  /// Real, mutable state emitter so tests (and the controller under test)
  /// can subscribe and push transitions. Exposed via [state].
  final _FakeStateEmitter<CallState> stateNotifier;

  @override
  StateEmitter<CallState> get state => stateNotifier;
}

/// Test-only [MutableStateEmitter] backed by a broadcast [StreamController].
///
/// We can't reuse the SDK's `MutableStateEmitterImpl` because it isn't
/// exported (`stream_video` only exports the abstract `MutableStateEmitter`
/// + `StateEmitter` typenames). Reimplementing the methods our controller
/// actually touches — `value`, `listen`, the value setter — is enough for
/// the unit test seam.
class _FakeStateEmitter<T> extends MutableStateEmitter<T> {
  _FakeStateEmitter(this._value);

  T _value;
  // Sync broadcast so events flush in the same microtask the test sets the
  // `value` setter — keeps tester pumps deterministic without needing
  // `pumpAndSettle`.
  final StreamController<T> _ctrl = StreamController<T>.broadcast(sync: true);

  @override
  T get value => _value;

  @override
  set value(T newValue) {
    _value = newValue;
    _ctrl.add(newValue);
  }

  @override
  bool get hasValue => true;

  @override
  T? get valueOrNull => _value;

  @override
  Stream<T> get valueStream => _ctrl.stream;

  @override
  Sink<T> get valueSink => _ctrl.sink;

  @override
  Future<dynamic> close() => _ctrl.close();

  @override
  StreamSubscription<T> listen(
    void Function(T value)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _ctrl.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  Stream<T> asStream() => _ctrl.stream;

  @override
  Future<E> waitFor<E extends T>({required Duration timeLimit}) =>
      firstWhere((it) => it is E, timeLimit: timeLimit).then((it) => it as E);

  @override
  Future<T> firstWhere(
    bool Function(T element) test, {
    T Function()? orElse,
    required Duration timeLimit,
  }) =>
      _ctrl.stream.firstWhere(test, orElse: orElse).timeout(timeLimit);
}

/// Minimal [CallParticipantState] builder for waiting-banner tests. Fills only
/// the required positional/keyword fields of the SDK constructor — the gate
/// predicate reads `isLocal`, nothing else.
CallParticipantState fakeParticipant({
  required bool isLocal,
  String userId = 'p',
}) {
  return CallParticipantState(
    userId: userId,
    roles: const ['user'],
    name: userId,
    custom: const {},
    sessionId: 's-$userId',
    trackIdPrefix: 't-$userId',
    isLocal: isLocal,
  );
}
