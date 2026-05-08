import 'package:stream_video_flutter/stream_video_flutter.dart' show Call;

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
    this.call,
  });

  final ActiveCallMode mode;
  final String? callId;
  final String? callType;
  final bool audioOnly;

  /// Live Stream `Call` — non-null once `_join` succeeds, null once the
  /// controller resets. Intentionally not part of equality (`Call` instances
  /// are reference-identity already; comparing two states with the same
  /// `Call` reference is the only meaningful equality and we get it via the
  /// other fields).
  final Call? call;

  /// Note: `clearCall: true` is required to null out [call], because
  /// `?? this.call` cannot ever produce a null result on its own.
  ActiveCallState copyWith({
    ActiveCallMode? mode,
    String? callId,
    String? callType,
    bool? audioOnly,
    Call? call,
    bool clearCall = false,
  }) =>
      ActiveCallState(
        mode: mode ?? this.mode,
        callId: callId ?? this.callId,
        callType: callType ?? this.callType,
        audioOnly: audioOnly ?? this.audioOnly,
        call: clearCall ? null : (call ?? this.call),
      );

  static const idle = ActiveCallState();

  // Plain Dart `==` / `hashCode` / `toString`. The repo intentionally has
  // no codegen (no equatable, no freezed). `call` is excluded from equality
  // because `Call` instances already identify by reference and including
  // them would conflate "same logical call" with "same instance".
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActiveCallState &&
          runtimeType == other.runtimeType &&
          mode == other.mode &&
          callId == other.callId &&
          callType == other.callType &&
          audioOnly == other.audioOnly;

  @override
  int get hashCode => Object.hash(mode, callId, callType, audioOnly);

  @override
  String toString() =>
      'ActiveCallState(mode: $mode, callId: $callId, callType: $callType, '
      'audioOnly: $audioOnly, call: ${call == null ? 'null' : 'live'})';
}
