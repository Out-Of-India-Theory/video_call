import 'package:flutter/foundation.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../config.dart';
import '../errors.dart';
import '../screen/call_session.dart';
import 'active_call_state.dart';

/// Returned by [ActiveCallController.connectAndJoin] so the screen knows
/// what to render: ready (call live), or errored.
sealed class ConnectResult {}

class ConnectReady extends ConnectResult {
  ConnectReady(this.call);

  final Call call;
}

class ConnectErrored extends ConnectResult {
  ConnectErrored(this.code, this.message);

  final OitVideoCallErrorCode code;
  final String message;
}

/// Owns the lifetime of the in-flight call so it survives `Navigator.pop`.
///
/// In v1 the call lived inside `CallScreen` State and `dispose()` ended it.
/// For in-app PiP the call must outlive the route — when the user taps back
/// or "minimize", we pop the route but the connection stays alive and the
/// host renders [MinimizedCallView] above the navigator.
class ActiveCallController extends ChangeNotifier {
  /// Defaults to [StreamCallSession] so production callers don't need to
  /// think about it; tests pass a [FakeCallSession] (or any other
  /// [CallSession] impl).
  ActiveCallController({CallSession? session})
      : _session = session ?? StreamCallSession();

  final CallSession _session;

  ActiveCallState _state = ActiveCallState.idle;
  ActiveCallState get state => _state;

  /// Monotonically increasing token used by [connectAndJoin] to detect
  /// cancellation. [endCall] / [reset] bump it; the running attempt sees the
  /// mismatch after its next `await`, cleans up any partially-constructed
  /// call, and returns [ConnectErrored] instead of silently committing a
  /// connected state to a controller the caller has already torn down.
  int _connectEpoch = 0;

  /// Phases 2–5 of the v1 `_start()`: token → connect → getCall → join.
  /// On success, mode flips to `connected` and `state.call` is non-null.
  ///
  /// Throws [StateError] if invoked with a different `callId` while another
  /// call is already in progress; if the same `callId` is re-entered after a
  /// successful connect, the existing live [Call] is returned via
  /// [ConnectReady] and no new I/O is performed.
  ///
  /// To retry after a [ConnectErrored] result, callers must invoke [reset]
  /// first (the controller refuses to re-connect when the state isn't
  /// `idle`).
  Future<ConnectResult> connectAndJoin({
    required OitVideoCallConfig config,
    required String callId,
    required String callType,
    required bool audioOnly,
    required bool createIfMissing,
  }) async {
    if (_state.mode == ActiveCallMode.idle) {
      _state = ActiveCallState(
        mode: ActiveCallMode.connecting,
        callId: callId,
        callType: callType,
        audioOnly: audioOnly,
      );
      notifyListeners();
    } else if (_state.callId != callId) {
      // Re-entering with a different call id while another is active is a
      // bug at the host-app level; bail loudly.
      throw StateError(
        'Active call already in progress for ${_state.callId}; '
        'cannot start $callId.',
      );
    } else if (_state.call != null) {
      // Already connected — observer is just re-mounting (e.g. tap-to-expand).
      return ConnectReady(_state.call!);
    }

    // Stamp this attempt with an epoch so [endCall]/[reset] can cancel it.
    final epoch = ++_connectEpoch;
    bool isCancelled() => _connectEpoch != epoch;

    // Phase 2: token
    final String token;
    try {
      token = await config.tokenProvider();
    } catch (_) {
      return ConnectErrored(
        OitVideoCallErrorCode.tokenFetchFailed,
        'Could not fetch call token.',
      );
    }
    if (isCancelled()) {
      // No SDK state to clean up yet — token fetch is pure host-side.
      return ConnectErrored(OitVideoCallErrorCode.unknown, 'Cancelled');
    }

    // Phase 3: connect
    try {
      final user = User.regular(
        userId: config.user.id,
        name: config.user.name,
        image: config.user.image,
      );
      await _session.connect(apiKey: config.apiKey, user: user, token: token);
    } catch (_) {
      return ConnectErrored(
        OitVideoCallErrorCode.joinFailed,
        'Could not connect to call service.',
      );
    }
    if (isCancelled()) {
      // Best-effort: dispose the SDK singleton we just constructed.
      // [endCall] already disposes, so this is a double-dispose — safe
      // per Stream docs.
      try {
        await _session.dispose();
      } catch (_) {
        // best-effort
      }
      return ConnectErrored(OitVideoCallErrorCode.unknown, 'Cancelled');
    }

    // Phase 4: get / get-or-create
    final Call call;
    try {
      call = createIfMissing
          ? await _session.getOrCreateCall(callType: callType, callId: callId)
          : await _session.getCall(callType: callType, callId: callId);
    } on CallNotFoundError {
      return ConnectErrored(
        OitVideoCallErrorCode.callNotFound,
        'Call not available.',
      );
    } catch (_) {
      return ConnectErrored(
        OitVideoCallErrorCode.joinFailed,
        createIfMissing ? 'Could not start call.' : 'Could not load call.',
      );
    }
    if (isCancelled()) {
      // Tear down the partially-set-up call before returning.
      try {
        await _session.leaveCall(call);
      } catch (_) {
        // best-effort
      }
      try {
        await _session.dispose();
      } catch (_) {
        // best-effort
      }
      return ConnectErrored(OitVideoCallErrorCode.unknown, 'Cancelled');
    }

    // Phase 5: join
    try {
      await _session.joinCall(call);
      if (audioOnly) {
        await _session.setCameraEnabled(call, false);
      }
    } catch (_) {
      return ConnectErrored(
        OitVideoCallErrorCode.joinFailed,
        'Could not join call.',
      );
    }
    if (isCancelled()) {
      // We joined, but caller cancelled — clean up the live call.
      try {
        await _session.leaveCall(call);
      } catch (_) {
        // best-effort
      }
      try {
        await _session.dispose();
      } catch (_) {
        // best-effort
      }
      return ConnectErrored(OitVideoCallErrorCode.unknown, 'Cancelled');
    }

    _state = _state.copyWith(mode: ActiveCallMode.connected, call: call);
    notifyListeners();
    return ConnectReady(call);
  }

  /// Kept for callers that want to flip into `connecting` without performing
  /// I/O (e.g. unit tests, future-task host-app code). [connectAndJoin] does
  /// this transition internally for you.
  @visibleForTesting
  void beginConnecting({
    required String callId,
    required String callType,
    required bool audioOnly,
  }) {
    if (_state.mode != ActiveCallMode.idle) {
      throw StateError(
        'Cannot beginConnecting from mode ${_state.mode}. '
        'Reset the controller first.',
      );
    }
    _state = ActiveCallState(
      mode: ActiveCallMode.connecting,
      callId: callId,
      callType: callType,
      audioOnly: audioOnly,
    );
    notifyListeners();
  }

  /// Test-only: forces the controller into `minimized` with a null `call`.
  /// Lets host-widget tests pump the [MinimizedCallView] without standing up a
  /// fully-mocked Stream [Call] (whose state/partialState getters would
  /// otherwise need stubbing). The resulting mini view falls into the
  /// "no call yet" branch and renders its placeholders for video and mic,
  /// while leaving the End button and host wiring fully intact.
  @visibleForTesting
  void debugForceMinimizedForTest({
    required String callId,
    required String callType,
    bool audioOnly = false,
  }) {
    _state = ActiveCallState(
      mode: ActiveCallMode.minimized,
      callId: callId,
      callType: callType,
      audioOnly: audioOnly,
    );
    notifyListeners();
  }

  /// Returns true when the transition was applied; false when ignored
  /// because the call isn't in a minimizable mode.
  bool minimize() {
    if (_state.mode != ActiveCallMode.connected &&
        _state.mode != ActiveCallMode.fastReconnecting) {
      return false;
    }
    _state = _state.copyWith(mode: ActiveCallMode.minimized);
    notifyListeners();
    return true;
  }

  /// Returns true when the transition was applied; false when ignored.
  bool expand() {
    if (_state.mode != ActiveCallMode.minimized) return false;
    _state = _state.copyWith(mode: ActiveCallMode.connected);
    notifyListeners();
    return true;
  }

  /// Permanent end. Tears down the SDK call, resets state, notifies.
  Future<void> endCall() async {
    // Cancel any in-flight [connectAndJoin] so a late commit can't flip us
    // back to `connected` after we've already torn down.
    _connectEpoch++;
    final call = _state.call;
    _state = _state.copyWith(mode: ActiveCallMode.ending);
    notifyListeners();
    if (call != null) {
      try {
        await _session.leaveCall(call);
      } catch (_) {
        // best-effort
      }
    }
    await _session.dispose();
    _state = ActiveCallState.idle;
    notifyListeners();
  }

  /// Synchronous reset — used in tests and during host-app sign-out where
  /// no live `Call` exists, and to allow [connectAndJoin] to be retried
  /// after a [ConnectErrored] result. Production code that has a live call
  /// should prefer [endCall].
  void reset() {
    // Same cancellation semantics as [endCall] for any in-flight attempt.
    _connectEpoch++;
    _state = ActiveCallState.idle;
    notifyListeners();
  }
}
