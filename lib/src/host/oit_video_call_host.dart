import 'package:flutter/material.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

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
/// The host listens to [OitVideoCall.activeControllerListenable], so it works
/// whether [OitVideoCall.init] is called before this widget mounts (typical
/// for apps that init at startup) or after (typical for apps that init
/// lazily, e.g. on the first "Join Call" tap once the user profile is loaded).
class OitVideoCallHost extends StatefulWidget {
  const OitVideoCallHost({
    super.key,
    required this.child,
    this.minimizedBuilder,
    this.onExpandRequested,
    this.navigatorKey,
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

  /// Optional navigator key — pass the same `GlobalKey<NavigatorState>` you
  /// hand to `MaterialApp.navigatorKey` / `MaterialApp.router`'s router
  /// delegate. The host uses it to push the expand-route and to scope the
  /// `confirmLeave` prompt for the mini's End button.
  ///
  /// **Strongly recommended in production apps.** Without it, the host falls
  /// back to walking the element tree to find the topmost `NavigatorState` —
  /// which works for canonical single-`MaterialApp` setups but isn't a
  /// public framework contract and can pick the wrong navigator in
  /// multi-`MaterialApp` / add-to-app / shell-embedded apps.
  final GlobalKey<NavigatorState>? navigatorKey;

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
    OitVideoCall.activeControllerListenable.addListener(_onActiveControllerChanged);
    _attachToActiveController();
  }

  @override
  void dispose() {
    OitVideoCall.activeControllerListenable.removeListener(_onActiveControllerChanged);
    _controller?.removeListener(_onChange);
    super.dispose();
  }

  /// Fires when [OitVideoCall.init], [OitVideoCall.initForTest], or
  /// [OitVideoCall.reset] swap the active controller. We re-attach so apps
  /// that mount the host before calling `init()` still get PiP wired up.
  void _onActiveControllerChanged() {
    if (!mounted) return;
    _attachToActiveController();
  }

  void _attachToActiveController() {
    final next = OitVideoCall.activeControllerListenable.value;
    if (identical(next, _controller)) return;
    _controller?.removeListener(_onChange);
    _controller = next;
    _controller?.addListener(_onChange);
    final shouldMinimize =
        _controller?.state.mode == ActiveCallMode.minimized;
    if (shouldMinimize != _isMinimized) {
      setState(() => _isMinimized = shouldMinimize);
    }
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
    if (!_isMinimized || c == null) {
      // Pass-through: avoid the FloatingViewContainer's LayoutBuilder +
      // AnimationController overhead when there's nothing to float.
      return widget.child;
    }
    final floatingView = widget.minimizedBuilder?.call(context, c) ??
        MinimizedCallView(
          controller: c,
          onExpand: () => _onExpandRequested(context, c),
          onEnd: () => _onEndRequested(context, c),
        );
    // Stream's FloatingViewContainer provides drag + corner-snap for free.
    // We feed it the wrapped subtree as `child` and our card as `floatingView`.
    return FloatingViewContainer(
      floatingViewWidth: MinimizedCallView.width,
      floatingViewHeight: MinimizedCallView.height,
      floatingView: floatingView,
      child: widget.child,
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
    // The host's [BuildContext] sits ABOVE the app's Navigator (apps wire
    // the host through `MaterialApp.builder`, which puts us a level above
    // the router), so `Navigator.of(context, rootNavigator: true)` walks up
    // and finds nothing — push silently no-ops. Prefer the explicit
    // [navigatorKey] when supplied; otherwise walk DOWN from the root
    // element to find the topmost Navigator as a best-effort fallback.
    final navigator = _resolveNavigator();
    if (navigator == null) return;
    navigator.push<void>(
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

  /// End-call handler for the minimized view's red phone icon.
  ///
  /// Mirrors the back-press flow in `CallScreen` — if the host app passed a
  /// `confirmLeave` to [OitVideoCall.callScreen], we await that prompt and
  /// only end the call when the user confirms. Without `confirmLeave` (or
  /// with the cached args missing for any reason — e.g. the facade was reset
  /// while a mini was still on screen) we fall through to [endCall] directly,
  /// which keeps the historical "tap End → call ends" behavior for hosts that
  /// haven't opted into a confirmation dialog.
  ///
  /// The `mode != minimized` guard at the top serializes concurrent invocations:
  /// a double-tap on End sends one through the confirm prompt and short-circuits
  /// the second once `endCall` has flipped the controller out of `minimized`.
  /// It also defends against future natural-disconnect handlers flipping the
  /// mode while the user's confirmLeave sheet is open.
  Future<void> _onEndRequested(
    BuildContext context,
    ActiveCallController c,
  ) async {
    if (c.state.mode != ActiveCallMode.minimized) return;
    final confirm = OitVideoCall.lastArgsOrNull?.confirmLeave;
    if (confirm != null) {
      // `confirm` (e.g. `showModalBottomSheet`) needs a context that has the
      // app's Navigator above it. The host's own context sits above the
      // Navigator, so we hand off the navigator-overlay's context — that's
      // a descendant of the Navigator and resolves correctly.
      final navigator = _resolveNavigator();
      final overlayContext = navigator?.overlay?.context;
      if (overlayContext == null) {
        // No Navigator reachable. Bail without ending the call — silently
        // ending a live consultation because of a transient lookup miss is
        // worse than the user re-tapping once a navigator is mounted.
        debugPrint(
          'OitVideoCallHost: cannot show confirmLeave — no Navigator '
          'reachable. Aborting end-call so the call is not silently '
          'terminated without confirmation. Pass `navigatorKey` to skip '
          'the down-tree walk.',
        );
        return;
      }
      final ok = await confirm(overlayContext);
      if (!ok || !mounted) return;
    }
    await c.endCall();
  }

  /// Returns the [NavigatorState] to use for tap-to-expand pushes and the
  /// confirmLeave prompt scope. Prefers [OitVideoCallHost.navigatorKey] when
  /// supplied (the recommended path), otherwise falls back to the down-tree
  /// walk.
  NavigatorState? _resolveNavigator() =>
      widget.navigatorKey?.currentState ?? _findTopmostNavigator();

  /// Walks down from [WidgetsBinding.rootElement] and returns the first
  /// [NavigatorState] found in the element tree. Best-effort fallback for
  /// callers that don't supply [OitVideoCallHost.navigatorKey] — works for
  /// canonical single-`MaterialApp` setups but isn't a public framework
  /// contract.
  NavigatorState? _findTopmostNavigator() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    NavigatorState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        found = element.state as NavigatorState;
        return;
      }
      element.visitChildren(visit);
    }
    root.visitChildren(visit);
    return found;
  }
}
