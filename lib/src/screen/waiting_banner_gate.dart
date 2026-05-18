import 'dart:async';

import 'package:flutter/material.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// Subscribes to [Call.state] and shows [child] only while the local user is
/// the sole participant. Latches "hide" the first time a remote joins — the
/// banner does not reappear if the remote drops mid-call.
///
/// Public to allow direct widget tests; not re-exported from the package
/// barrel, so host apps cannot depend on it.
@visibleForTesting
class WaitingBannerGate extends StatefulWidget {
  const WaitingBannerGate({super.key, required this.call, required this.child});

  final Call call;
  final Widget child;

  @override
  State<WaitingBannerGate> createState() => _WaitingBannerGateState();
}

class _WaitingBannerGateState extends State<WaitingBannerGate> {
  bool _latched = false;
  int? _lastCount;
  StreamSubscription<CallState>? _sub;

  @override
  void initState() {
    super.initState();
    // Synchronously inspect the current state so re-expanding into an
    // already-joined call doesn't flash the banner for a frame.
    if (_hasRemote(widget.call.state.value)) {
      _latched = true;
    }
    _sub = widget.call.state.listen(_onState);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onState(CallState state) {
    if (_latched) return;
    if (_hasRemote(state)) {
      setState(() => _latched = true);
      return;
    }
    final count = state.callParticipants.length;
    if (count != _lastCount) {
      _lastCount = count;
      setState(() {});
    }
  }

  bool _hasRemote(CallState state) =>
      state.callParticipants.any((p) => !p.isLocal);

  @override
  Widget build(BuildContext context) {
    if (_latched) return const SizedBox.shrink();
    return widget.child;
  }
}
