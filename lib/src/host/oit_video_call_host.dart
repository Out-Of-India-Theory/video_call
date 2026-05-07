import 'package:flutter/material.dart';

import '../active_call/active_call_controller.dart';
import '../active_call/active_call_state.dart';
import '../facade.dart';

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
  /// [DefaultMinimizedCallView] (Task 4).
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

  @override
  void initState() {
    super.initState();
    if (OitVideoCall.isInitialized) {
      _controller = OitVideoCall.controllerOrThrow
        ..addListener(_onChange);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final showMini =
        c != null && c.state.mode == ActiveCallMode.minimized;
    return Stack(
      children: [
        widget.child,
        if (showMini)
          // Builder defaults to DefaultMinimizedCallView (Task 4).
          widget.minimizedBuilder?.call(context, c) ??
              _PlaceholderMini(controller: c),
      ],
    );
  }
}

class _PlaceholderMini extends StatelessWidget {
  const _PlaceholderMini({required this.controller});
  final ActiveCallController controller;

  @override
  Widget build(BuildContext context) {
    // Replaced in Task 4. Kept here so Task 3 can be merged independently.
    return Positioned(
      right: 16,
      bottom: 16,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        child: const SizedBox(
          width: 120,
          height: 160,
          child: Center(
            child: Text(
              'Call',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
