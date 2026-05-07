import 'package:flutter/material.dart';

import '../active_call/active_call_controller.dart';
import '../active_call/active_call_state.dart';
import '../facade.dart';
import 'minimized_call_view.dart';

/// Host widget that renders the in-app PiP overlay above the app's navigator.
///
/// Apps wire this through `MaterialApp.builder`:
/// ```dart
/// MaterialApp.router(
///   builder: (ctx, child) => OitVideoCallHost(child: child!),
///   ...
/// );
/// ```
///
/// When [ActiveCallController.state.mode] is `minimized`, a draggable mini
/// window floats above the navigator. Otherwise the host is a no-op pass-through.
///
/// **Important:** Call [OitVideoCall.init] *before* mounting this widget. The
/// host attaches its controller listener once in `initState`; later calls to
/// `init()` are not observed and the host will silently never show PiP.
class OitVideoCallHost extends StatefulWidget {
  const OitVideoCallHost({
    super.key,
    required this.child,
    this.minimizedBuilder,
    this.onExpandRequested,
  });

  /// The wrapped subtree — typically `MaterialApp`'s navigator.
  final Widget child;

  /// Optional override for the minimized view. Defaults to
  /// [MinimizedCallView].
  final Widget Function(
    BuildContext context,
    ActiveCallController controller,
  )? minimizedBuilder;

  /// Optional handler called when the user taps the minimized view to
  /// expand. If null, the host falls back to pushing
  /// `OitVideoCall.callScreen(...)` onto the root Navigator.
  ///
  /// Apps using auto_route / go_router should wire this to push their own
  /// call route so the navigator stack remains consistent.
  final VoidCallback? onExpandRequested;

  @override
  State<OitVideoCallHost> createState() => _OitVideoCallHostState();
}

class _OitVideoCallHostState extends State<OitVideoCallHost> {
  ActiveCallController? _controller;

  /// Cached projection of `controller.state.mode == minimized` so the host
  /// only rebuilds when that single bit flips. Without this, every controller
  /// notification (token fetch, connect, join, etc.) would trigger a setState
  /// whose build output didn't actually change.
  bool _isMinimized = false;

  @override
  void initState() {
    super.initState();
    if (OitVideoCall.isInitialized) {
      _controller = OitVideoCall.controllerOrThrow
        ..addListener(_onChange);
      _isMinimized = _controller?.state.mode == ActiveCallMode.minimized;
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    final next = _controller?.state.mode == ActiveCallMode.minimized;
    if (next != _isMinimized) {
      setState(() => _isMinimized = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Stack(
      children: [
        widget.child,
        if (_isMinimized && c != null)
          widget.minimizedBuilder?.call(context, c) ??
              MinimizedCallView(
                controller: c,
                onExpand: () => _onExpandRequested(context, c),
                // Refined in Task 7 — for now this just ends the call without
                // a confirm prompt.
                onEnd: () async => c.endCall(),
              ),
      ],
    );
  }

  /// Two paths:
  ///
  ///   1. **App-handled** — when [OitVideoCallHost.onExpandRequested] is
  ///      non-null, the app pushes its own call route (auto_route /
  ///      go_router) so the navigator stack stays consistent with its
  ///      router state.
  ///   2. **Plugin-handled fallback** — push a [MaterialPageRoute] onto the
  ///      root [Navigator] that rebuilds the call screen using the args
  ///      cached on [OitVideoCall.lastArgsOrNull].
  ///
  /// The host does *not* call `c.expand()` directly. Both paths cause a new
  /// [CallScreen] to be mounted, and that screen flips the controller back
  /// to `connected` in its `initState` — at which point the host's listener
  /// removes this overlay. Doing the flip from the screen avoids a one-frame
  /// gap where the mini disappears before the route has rendered.
  ///
  /// The full route-pushing flow is exercised manually via the example app
  /// smoke test in Task 9; see `test/screen/call_screen_test.dart` for the
  /// `initState` flip unit test.
  void _onExpandRequested(BuildContext context, ActiveCallController c) {
    if (widget.onExpandRequested != null) {
      widget.onExpandRequested!();
      return;
    }
    // Plugin-handled fallback path. Should always have args because the
    // only way to reach `minimized` mode is via a connected call, which in
    // turn requires `OitVideoCall.callScreen()` to have been mounted at
    // least once. Guarded defensively all the same — if for any reason the
    // facade was reset while a mini is still on screen, we'd rather no-op
    // than crash.
    final args = OitVideoCall.lastArgsOrNull;
    if (args == null) return;
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OitVideoCall.callScreen(
          callId: args.callId,
          callType: args.callType,
          audioOnly: args.audioOnly,
          createIfMissing: args.createIfMissing,
          onCallEnded: args.onCallEnded,
          confirmLeave: args.confirmLeave,
        ),
      ),
    );
  }
}
