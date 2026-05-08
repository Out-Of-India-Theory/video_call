import 'package:flutter/material.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../active_call/active_call_controller.dart';

/// Floating mini-window content rendered inside Stream's [FloatingViewContainer]
/// by [OitVideoCallHost] when the active call is minimized.
///
/// Drag + corner-snap is provided by the surrounding [FloatingViewContainer];
/// this widget renders only the inner card content (120x160dp dark Material
/// card with rounded corners). Picks one participant to render in the tile,
/// preferring (in order):
///
///   1. The dominant speaker — whoever the SFU currently highlights, so the
///      mini follows the conversation.
///   2. The first remote participant — keeps the consultation peer visible
///      when no one's actively talking.
///   3. The first participant of any kind — covers solo / pre-join states
///      where only the local user is in the call. Without this, the user
///      would minimize and see a "Connecting…" placeholder despite being on
///      a live call.
///
/// "Connecting…" only shows if the participant list is empty (call object
/// not yet built, or every participant left). Bottom strip exposes three
/// controls: mic toggle, end-call (red), and expand. Tapping the video area
/// also expands.
class MinimizedCallView extends StatelessWidget {
  const MinimizedCallView({
    super.key,
    required this.controller,
    required this.onExpand,
    required this.onEnd,
  });

  /// Controller backing the call. Always non-null in production; the
  /// "Connecting…" placeholder branch is reached when `controller.state.call`
  /// is still null (e.g. the controller is in the `connecting` mode or just
  /// flipped into `minimized` before the SDK has a live `Call`).
  final ActiveCallController controller;

  /// Invoked when the user taps the video area or the expand icon.
  final VoidCallback onExpand;

  /// Invoked when the user taps the red end-call icon.
  final VoidCallback onEnd;

  /// Width passed to Stream's [FloatingViewContainer] by the host.
  static const double width = 120;

  /// Height passed to Stream's [FloatingViewContainer] by the host.
  static const double height = 160;

  @override
  Widget build(BuildContext context) {
    final call = controller.state.call;
    return Material(
      elevation: 8,
      color: Colors.black,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onExpand,
                child: _buildVideo(),
              ),
            ),
            _buildControls(call),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final call = controller.state.call;
    if (call == null) return const _Placeholder();

    return PartialCallStateBuilder<CallParticipantState?>(
      call: call,
      selector: (s) {
        final ps = s.callParticipants;
        // Dominant speaker → first remote → first of any kind. The fallback
        // chain ensures solo-test sessions still see the local tile instead
        // of an indefinite "Connecting…" placeholder.
        return ps.where((p) => p.isDominantSpeaker).firstOrNull ??
            ps.where((p) => !p.isLocal).firstOrNull ??
            ps.firstOrNull;
      },
      builder: (_, participant) {
        if (participant == null) return const _Placeholder();
        // Key by uniqueParticipantKey so renderer subscriptions are recreated
        // cleanly when the rendered participant changes (e.g. dominant
        // speaker switches). Matches Stream's own widget conventions.
        return StreamCallParticipant(
          key: ValueKey(participant.uniqueParticipantKey),
          call: call,
          participant: participant,
          showParticipantLabel: false,
          showSpeakerBorder: false,
        );
      },
    );
  }

  Widget _buildControls(Call? call) {
    final micButton = call != null
        ? PartialCallStateBuilder<bool>(
            call: call,
            selector: (s) => s.localParticipant?.isAudioEnabled ?? false,
            builder: (_, isOn) => IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              // Pass `isOn` from the builder closure (the latest visual state
              // at the time of tap) instead of reading `call.state.value`
              // synchronously inside `_toggleMic`. Two rapid taps on a
              // stale-icon view will then both act on the same value (intent:
              // mute) and the SDK serializes them — instead of cancelling
              // each other when the second tap re-reads a stale-or-fresh
              // local state that depends on SDK update timing.
              onPressed: () => _toggleMic(call, isOn),
              icon: Icon(
                isOn ? Icons.mic : Icons.mic_off,
                color: isOn ? Colors.white : Colors.redAccent,
              ),
            ),
          )
        : const IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: null,
            icon: Icon(Icons.mic, color: Colors.white54),
          );

    return Container(
      height: 40,
      color: Colors.black87,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          micButton,
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onEnd,
            icon: const Icon(Icons.call_end, color: Colors.redAccent),
          ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onExpand,
            icon: const Icon(Icons.fullscreen, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMic(Call call, bool isOn) async {
    await call.setMicrophoneEnabled(enabled: !isOn);
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Connecting…',
              style: TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
