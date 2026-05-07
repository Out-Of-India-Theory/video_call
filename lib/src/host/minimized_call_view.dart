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

  /// Initialized lazily in [didChangeDependencies] once a [MediaQuery] is
  /// available so we can place the mini at the top-right inset.
  Offset? _offset;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_offset == null) {
      final media = MediaQuery.of(context);
      _offset = Offset(
        media.size.width - _width - _margin,
        media.padding.top + _margin,
      );
    }
  }

  /// Clamps [raw] inside the safe-area-adjusted viewport for the current
  /// [MediaQueryData]. Used both when writing on drag (so the offset never
  /// accumulates off-screen) and when reading on build (so orientation
  /// changes can't leave a stale offset out of bounds).
  Offset _clampToViewport(Offset raw, MediaQueryData media) {
    const minX = _margin;
    final minY = media.padding.top + 8;
    final maxXraw = media.size.width - _width - _margin;
    final maxYraw =
        media.size.height - _height - _margin - media.padding.bottom;
    // Defensive: on very small screens max could fall below min.
    final maxX = maxXraw < minX ? minX : maxXraw;
    final maxY = maxYraw < minY ? minY : maxYraw;
    return Offset(
      raw.dx.clamp(minX, maxX).toDouble(),
      raw.dy.clamp(minY, maxY).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Re-clamp on read as a safety net for orientation changes; the
    // write-time clamp in onPanUpdate already keeps drags in bounds.
    final offset = _clampToViewport(_offset!, media);
    final call = widget.controller?.state.call;

    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          final media = MediaQuery.of(context);
          _offset = _clampToViewport(_offset! + d.delta, media);
        }),
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
                _buildControls(call),
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
        // Key by uniqueParticipantKey so renderer subscriptions are recreated
        // cleanly when the remote participant changes (matches Stream's own
        // widget conventions).
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

  Widget _buildControls(Call? call) {
    final micButton = call != null
        ? PartialCallStateBuilder<bool>(
            call: call,
            selector: (s) => s.localParticipant?.isAudioEnabled ?? false,
            builder: (_, isOn) => IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: _toggleMic,
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
    final isOn =
        call.state.value.localParticipant?.isAudioEnabled ?? false;
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
