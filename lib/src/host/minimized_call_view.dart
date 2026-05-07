import 'package:flutter/material.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

import '../active_call/active_call_controller.dart';

/// Floating mini-window rendered by [OitVideoCallHost] when the active call is
/// minimized.
///
/// 120x160dp rounded card, dark background, draggable around the screen with
/// safe-area clamping. Renders only the **first remote** participant
/// (`participants.where((p) => !p.isLocal).firstOrNull`); the local participant
/// is intentionally never shown here. While no remote participant is present
/// (call still null, joining, or remote hasn't arrived yet) we show a small
/// "Connecting..." placeholder.
///
/// Bottom strip exposes three controls: mic toggle, end-call (red), and
/// expand. Tapping the video area also expands.
class MinimizedCallView extends StatefulWidget {
  const MinimizedCallView({
    super.key,
    required this.controller,
    required this.onExpand,
    required this.onEnd,
  });

  /// Visible only for the placeholder unit test. Renders the
  /// "Connecting..." branch without needing a live [ActiveCallController].
  @visibleForTesting
  const MinimizedCallView.placeholderForTest({super.key})
      : controller = null,
        onExpand = null,
        onEnd = null;

  /// Controller backing the call. Nullable so the
  /// [MinimizedCallView.placeholderForTest] constructor can be `const`.
  /// Real production usage always passes a non-null controller.
  final ActiveCallController? controller;

  /// Invoked when the user taps the video area or the expand icon.
  final VoidCallback? onExpand;

  /// Invoked when the user taps the red end-call icon.
  final VoidCallback? onEnd;

  @override
  State<MinimizedCallView> createState() => _MinimizedCallViewState();
}

class _MinimizedCallViewState extends State<MinimizedCallView> {
  static const double _width = 120;
  static const double _height = 160;
  static const double _margin = 16;

  Offset _offset = const Offset(_margin, 80);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxX = media.size.width - _width - _margin;
    final maxY =
        media.size.height - _height - _margin - media.padding.bottom;
    final minY = media.padding.top + 8;

    // Defensive clamp: on very small screens the max could fall below the min.
    final clampedX = _offset.dx.clamp(_margin, maxX < _margin ? _margin : maxX);
    final clampedY = _offset.dy.clamp(minY, maxY < minY ? minY : maxY);

    return Positioned(
      left: clampedX,
      top: clampedY,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() => _offset += d.delta),
        onTap: widget.onExpand,
        child: Material(
          elevation: 8,
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: _width,
            height: _height,
            child: Column(
              children: [
                Expanded(child: _buildVideo()),
                _buildControls(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final controller = widget.controller;
    if (controller == null) {
      // placeholderForTest path.
      return const _Placeholder();
    }
    final call = controller.state.call;
    if (call == null) return const _Placeholder();

    return PartialCallStateBuilder<CallParticipantState?>(
      call: call,
      selector: (s) =>
          s.callParticipants.where((p) => !p.isLocal).firstOrNull,
      builder: (_, remote) {
        if (remote == null) return const _Placeholder();
        return StreamCallParticipant(
          key: ValueKey(remote.uniqueParticipantKey),
          call: call,
          participant: remote,
          showParticipantLabel: false,
          showSpeakerBorder: false,
        );
      },
    );
  }

  Widget _buildControls() {
    return Container(
      height: 40,
      color: Colors.black87,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: _toggleMic,
            icon: const Icon(Icons.mic, color: Colors.white),
          ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: widget.onEnd,
            icon: const Icon(Icons.call_end, color: Colors.redAccent),
          ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: widget.onExpand,
            icon: const Icon(Icons.fullscreen, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMic() async {
    final call = widget.controller?.state.call;
    if (call == null) return;
    final enabled =
        call.state.value.localParticipant?.isAudioEnabled ?? false;
    await call.setMicrophoneEnabled(enabled: !enabled);
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
