import 'dart:async';

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

  /// Subscription to the live [Call]'s `state` emitter. Created after a
  /// successful join in [connectAndJoin]; cancelled by [endCall] before the
  /// SDK teardown and by the cancellation branches inside [connectAndJoin].
  /// Non-null only while the controller has a live `Call`.
  ///
  /// Drives two transitions:
  ///   * `disconnected` (server ended, network drop, duration timeout) →
  ///     [endCall] runs, taking the controller back to `idle` and dismissing
  ///     a minimized PiP if one is on screen.
  ///   * `fastReconnecting` ↔ `connected` flips the mode bit so the
  ///     back-press matrix in [CallScreen] can react.
  StreamSubscription<CallState>? _callStateSub;

  /// Phases 2–5 of the v1 `_start()`: token → connect → getCall → join.
  /// On success, mode flips to `connected` and `state.call` is non-null.
  ///
  /// Returns [ConnectErrored] with [OitVideoCallErrorCode.unknown] if invoked
  /// with a different `callId` while another call is already in progress; if
  /// the same `callId` is re-entered after a successful connect, the existing
  /// live [Call] is returned via [ConnectReady] and no new I/O is performed.
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
      // host-app bug; surface it via ConnectErrored so the screen renders
      // the error UI instead of leaving an unhandled StateError to silently
      // hang the spinner. `_start()` is fire-and-forget from `initState`,
      // so a thrown error would surface as an unhandled future error.
      return ConnectErrored(
        OitVideoCallErrorCode.unknown,
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
      // If `joinCall` succeeded but `setCameraEnabled` failed, the call is
      // fully joined and would otherwise be leaked (no `leaveCall`, no
      // `dispose`). Mirror the cancellation branches above with best-effort
      // cleanup so a partial-success failure path doesn't strand SDK
      // resources.
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

    // Subscribe BEFORE notifyListeners so a synchronous observer that calls
    // endCall() inside its listener finds the subscription already in place
    // (and gets cancelled cleanly by endCall) rather than seeing it appear
    // afterward and leaking. We `unawaited` any stale subscription's cancel
    // (defense-in-depth; cleanup branches above null it out already) because
    // awaiting `StreamSubscription.cancel` deadlocks a `flutter_test`
    // `FakeAsync` zone — see [endCall] for details.
    final stale = _callStateSub;
    _callStateSub = null;
    if (stale != null) unawaited(stale.cancel());
    _callStateSub = call.state.listen(_onSdkCallStateChanged);

    notifyListeners();
    return ConnectReady(call);
  }

  /// Reacts to the SDK's `Call.state` updates.
  ///
  /// * `disconnected` → [endCall] (the leave-in-progress guard inside
  ///   `CallScreen` keeps re-entry idempotent).
  /// * `fastReconnecting` while we're `connected` → flip to
  ///   `fastReconnecting` (the back-press matrix in [CallScreen]
  ///   distinguishes the two modes).
  /// * `connected` while we're `fastReconnecting` → flip back.
  ///
  /// Other transitions (joining, joined, idle) are ignored — the controller
  /// already commits its own `connected` mode at the end of [connectAndJoin]
  /// and we don't want to fight the SDK's intermediate joining states.
  void _onSdkCallStateChanged(CallState cs) {
    final status = cs.status;
    if (status.isDisconnected) {
      unawaited(endCall());
      return;
    }
    if (status.isFastReconnecting &&
        _state.mode == ActiveCallMode.connected) {
      _state = _state.copyWith(mode: ActiveCallMode.fastReconnecting);
      notifyListeners();
      return;
    }
    if (status.isConnected &&
        _state.mode == ActiveCallMode.fastReconnecting) {
      _state = _state.copyWith(mode: ActiveCallMode.connected);
      notifyListeners();
      return;
    }
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
  void forceMinimizedForTest({
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
  ///
  /// When [forEveryone] is true, attempts to terminate the call for **all**
  /// participants on the Stream coordinator (used by the mitra app when an
  /// astrologer marks a consultation complete — the customer's connection
  /// is severed too). Falls back to a plain leave if the server rejects
  /// the end-for-all request (typically a permission issue) so the local
  /// user is always out regardless. Default `false` preserves the original
  /// "leave only" behavior for back-press / mini-End / natural-disconnect
  /// paths.
  Future<void> endCall({bool forEveryone = false}) async {
    // Idempotent: a no-op when already idle, and a no-op when a previous
    // invocation is still in flight (`ending`). The first guard prevents
    // spurious `ending → idle` notification cycles on duplicate calls (e.g.
    // host app's lifecycle observer + the SDK disconnect listener firing in
    // close succession). The `ending` guard prevents a second invocation
    // (e.g. user taps End in the mini AND a host-app lifecycle observer
    // triggers an end) from running `leaveCall` + `dispose` concurrently
    // with a still-awaiting first invocation.
    if (_state.mode == ActiveCallMode.idle ||
        _state.mode == ActiveCallMode.ending) {
      return;
    }
    // Cancel any in-flight [connectAndJoin] so a late commit can't flip us
    // back to `connected` after we've already torn down.
    _connectEpoch++;
    // Stop reacting to SDK call-state updates before we tear down — without
    // this, the SDK's transition to `disconnected` during `leaveCall` would
    // re-enter `endCall` recursively. We `unawaited` the cancel because in
    // a `flutter_test` `FakeAsync` zone, `await sub.cancel()` poisons the
    // microtask queue and any subsequent await deadlocks the test. The
    // listener stops firing synchronously the moment cancel is invoked, so
    // we don't need to wait for the returned Future to settle.
    final sub = _callStateSub;
    _callStateSub = null;
    if (sub != null) unawaited(sub.cancel());
    final call = _state.call;
    _state = _state.copyWith(mode: ActiveCallMode.ending);
    notifyListeners();
    if (call != null) {
      if (forEveryone) {
        try {
          await _session.endCallForEveryone(call);
          // call.end() also leaves locally as a side effect, so the
          // fallback below would short-circuit if it fires. Skip it.
        } catch (_) {
          // Permission denied / invalid call status. Fall back to a
          // plain leave so we at least exit the call from our side.
          try {
            await _session.leaveCall(call);
          } catch (_) {
            // best-effort
          }
        }
      } else {
        try {
          await _session.leaveCall(call);
        } catch (_) {
          // best-effort
        }
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
    // Best-effort fire-and-forget cancel — `reset()` is synchronous so we
    // can't await. In practice this is only used in tests / host-app
    // sign-out where no live call exists, but defending against the
    // late-disconnect re-entry is cheap.
    unawaited(_callStateSub?.cancel());
    _callStateSub = null;
    _state = ActiveCallState.idle;
    notifyListeners();
  }
}
