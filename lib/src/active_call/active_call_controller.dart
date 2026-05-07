import 'package:flutter/foundation.dart';

import 'active_call_state.dart';

/// Owns the lifetime of the in-flight call so it survives `Navigator.pop`.
///
/// In v1 the call lived inside `CallScreen` State and `dispose()` ended it.
/// For in-app PiP the call must outlive the route — when the user taps back
/// or "minimize", we pop the route but the connection stays alive and the
/// host renders [MinimizedCallView] above the navigator.
///
/// This skeleton task ships only state-machine plumbing. Network I/O and
/// `Call` ownership are added in Task 2.
class ActiveCallController extends ChangeNotifier {
  ActiveCallController();

  ActiveCallState _state = ActiveCallState.idle;
  ActiveCallState get state => _state;

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

  void reset() {
    _state = ActiveCallState.idle;
    notifyListeners();
  }
}
