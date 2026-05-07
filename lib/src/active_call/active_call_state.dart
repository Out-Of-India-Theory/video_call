/// Lifecycle of the active 1:1 call as observed by [ActiveCallController].
///
/// Transitions are linear and one-way except for `connected ↔ minimized`
/// which the user toggles via back-press / tap-to-expand:
///
///   idle → connecting → connected ⇄ minimized → ending → idle
///                            ↑
///                    fastReconnecting
enum ActiveCallMode {
  idle,
  connecting,
  connected,
  fastReconnecting,
  minimized,
  ending,
}

class ActiveCallState {
  const ActiveCallState({
    this.mode = ActiveCallMode.idle,
    this.callId,
    this.callType,
    this.audioOnly = false,
  });

  final ActiveCallMode mode;
  final String? callId;
  final String? callType;
  final bool audioOnly;

  ActiveCallState copyWith({
    ActiveCallMode? mode,
    String? callId,
    String? callType,
    bool? audioOnly,
  }) =>
      ActiveCallState(
        mode: mode ?? this.mode,
        callId: callId ?? this.callId,
        callType: callType ?? this.callType,
        audioOnly: audioOnly ?? this.audioOnly,
      );

  static const idle = ActiveCallState();
}
