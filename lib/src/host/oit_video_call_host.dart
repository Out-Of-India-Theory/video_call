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
                onExpand: () => _onExpandRequested(c),
                // Refined in Task 7 — for now this just ends the call without
                // a confirm prompt.
                onEnd: () async => c.endCall(),
              ),
      ],
    );
  }

  void _onExpandRequested(ActiveCallController c) {
    // Refined in Task 6 (route-pushing). For now we just flip the controller
    // out of minimized mode and notify the optional app-level callback.
    c.expand();
    widget.onExpandRequested?.call();
  }
}
