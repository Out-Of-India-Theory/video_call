import 'dart:async';

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

  /// Test-only override that replaces the call to
  /// `AndroidPipManager.instance().setPictureInPictureAllowed(...)` made by
  /// the chained re-assert timer (see
  /// [_OitVideoCallHostState._scheduleAndroidPipReassert]).
  ///
  /// Setting this also flips the platform / live-call gate that ordinarily
  /// guards the scheduler so widget tests can drive the timer chain on a
  /// test host (Mac/Linux/iOS CI) without standing up a real Stream
  /// [Call] or hitting the `stream_video_flutter_android_pip` method
  /// channel — both of which short-circuit on non-Android via
  /// `CurrentPlatform.isAndroid` reads against `dart:io`'s `Platform`.
  ///
  /// Production code paths are unaffected when this is `null` (the
  /// default). Tests that assign a value MUST clear it in `tearDown`
  /// otherwise subsequent tests will inherit the override.
  @visibleForTesting
  static void Function(bool allowed)? debugSetPictureInPictureAllowedOverride;

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

  /// Pending re-assertion of `setPictureInPictureAllowed(true)` — see
  /// [_scheduleAndroidPipReassert] for the race it papers over.
  Timer? _pipReassertTimer;

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
    _pipReassertTimer?.cancel();
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
      if (next && _shouldScheduleAndroidPipReassert()) {
        _scheduleAndroidPipReassert();
      }
    }
  }

  /// Production path: only schedule on Android with a live `Call`.
  /// Test path: when [OitVideoCallHost.debugSetPictureInPictureAllowedOverride]
  /// is set, schedule unconditionally so the chain can be exercised on a
  /// non-Android host without a real `Call`. See the override's dartdoc for
  /// why neither gate is bypassable in a test environment without this.
  bool _shouldScheduleAndroidPipReassert() {
    if (OitVideoCallHost.debugSetPictureInPictureAllowedOverride != null) {
      return true;
    }
    return _controller?.state.call != null && CurrentPlatform.isAndroid;
  }

  /// Workaround for a Stream-SDK race that breaks OS-level PiP after the
  /// in-app PiP transition.
  ///
  /// Sequence: user is in the full-screen call route (which mounts its own
  /// `StreamPictureInPictureAndroidView` inside `StreamCallContainer`).
  /// They press back → `minimize()` flips the controller mode →
  /// `_triggerPop` schedules `Navigator.pop`. The route's pop animation
  /// runs ~300ms before `CallScreen.dispose` actually fires; only THEN
  /// does the SDK's view dispose, calling
  /// `AndroidPipManager.setPictureInPictureAllowed(false)`. By that time
  /// the host's *new* (minimized-state) `StreamPictureInPictureAndroidView`
  /// has already mounted and called `setPictureInPictureAllowed(true)`
  /// from its initState. The late dispose-set-false races AFTER the
  /// init-set-true and wins, leaving the native flag at `false` — so when
  /// the user backgrounds the app from the mini,
  /// `PictureInPictureHelper.handlePipTrigger` sees the flag as false and
  /// doesn't call `enterPictureInPictureMode`.
  ///
  /// We can't predict exactly when the dispose fires (Material's default
  /// is ~300ms but apps with custom `PageTransitionsTheme` /
  /// `PageRouteBuilder` can push it well past 500ms), so a single fixed
  /// delay leaves both a vulnerability window (300–delay ms) AND a
  /// fragility cliff (custom transitions > delay). Sweep across plausible
  /// transition durations instead — whichever fire-time lands LAST after
  /// View_A's dispose wins. Cost is 4 platform-channel hits per minimize
  /// transition, each roughly free.
  ///
  /// Honors Stream's screen-share gate: when the local participant is
  /// screen-sharing AND the active configuration disables PiP during
  /// screen-share, we re-assert `false` so the timer doesn't paint over
  /// the SDK's intended behavior. Today the host hardcodes
  /// `disablePictureInPictureWhenScreenSharing: false` (matching what
  /// `CallScreen` passes to `StreamCallContainer`), but the read is in
  /// place for when that becomes configurable.
  void _scheduleAndroidPipReassert() {
    _pipReassertTimer?.cancel();
    const checkpoints = <int>[100, 250, 500, 1000];
    var i = 0;
    void scheduleNext() {
      if (i >= checkpoints.length) return;
      _pipReassertTimer = Timer(
        Duration(milliseconds: checkpoints[i]),
        () {
          i++;
          if (!mounted) return;
          final controller = _controller;
          if (controller?.state.mode != ActiveCallMode.minimized) return;
          final call = controller?.state.call;
          final override =
              OitVideoCallHost.debugSetPictureInPictureAllowedOverride;
          if (call == null && override == null) return;
          // Read screen-share state synchronously. Stream's view bails to
          // `setPictureInPictureAllowed(false)` here when its config has
          // `disablePictureInPictureWhenScreenSharing: true`; mirror the
          // same gate so we don't override the SDK's intent.
          final isScreenSharing = call
                  ?.state.value.localParticipant?.isScreenShareEnabled ??
              false;
          _setPictureInPictureAllowed(!isScreenSharing);
          scheduleNext();
        },
      );
    }

    scheduleNext();
  }

  /// Production path forwards to Stream's `AndroidPipManager`. Test path
  /// (when [OitVideoCallHost.debugSetPictureInPictureAllowedOverride] is
  /// non-null) hands the value to the override instead, bypassing the
  /// `stream_video_flutter_android_pip` method channel entirely. See the
  /// override's dartdoc.
  void _setPictureInPictureAllowed(bool allowed) {
    final override =
        OitVideoCallHost.debugSetPictureInPictureAllowedOverride;
    if (override != null) {
      override(allowed);
    } else {
      AndroidPipManager.instance().setPictureInPictureAllowed(allowed);
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
    // `bottomRight` matches the consumer / mitra UX expectation for PiP
    // tiles and keeps the floating window away from the AppBar; Stream's
    // default of `topRight` is overridden here.
    //
    // We let `floatingViewPadding` default to Stream's 16dp. Apps wire the
    // host through `MaterialApp.builder`, where the container that the
    // FloatingViewContainer sees is already safe-area-aware in practice
    // (the Scaffold below applies SafeArea to its body, and the wrapping
    // Material chrome accounts for status bar / gesture indicator). An
    // earlier dynamic-padding heuristic (max(16, viewPadding + 8)) shifted
    // the mini noticeably toward the middle in those layouts.
    final floatingContainer = FloatingViewContainer(
      floatingViewWidth: MinimizedCallView.width,
      floatingViewHeight: MinimizedCallView.height,
      floatingViewAlignment: FloatingViewAlignment.bottomRight,
      floatingView: floatingView,
      child: widget.child,
    );

    // Stream's platform PiP source views need to be in the widget tree
    // for the OS to pick them up when the app is backgrounded. While the
    // user is in the full-screen call route, `StreamCallContainer` mounts
    // these itself; once the route is popped (in-app PiP active), they
    // disappear and OS-level PiP stops working — the user backgrounds the
    // app and sees their home screen instead of a system PiP window. We
    // re-mount them here so OS PiP works whether the user is in
    // full-screen or minimized. Only do so when there's a live `Call` —
    // the platform views require a non-null `call`.
    final call = c.state.call;
    if (call == null) return floatingContainer;
    const pipConfig = PictureInPictureConfiguration(
      enablePictureInPicture: true,
    );
    return Stack(
      children: [
        // iOS: a `UiKitView` that the OS captures into the system PiP
        // window. Mirrors `StreamCallContainer`'s own mounting *exactly*
        // — non-Positioned `SizedBox(300, 600)`, default Stack alignment
        // (top-start). The full-screen path works; the in-app PiP path
        // didn't when this was wrapped in `Positioned(top: 0, left: 0,
        // width: 300, height: 600)` even though that should be
        // geometrically identical. Mixing Positioned and non-Positioned
        // children in a Stack routes through different RenderObject
        // paths; some platform-view compositing edge cases on iOS only
        // surface in the Positioned path and prevent
        // `AVPictureInPictureController` from registering the view as a
        // valid PiP source. Matching Stream's own pattern verbatim
        // bypasses that.
        if (CurrentPlatform.isIos)
          SizedBox(
            width: 300,
            height: 600,
            child: StreamPictureInPictureUiKitView(
              call: call,
              pictureInPictureConfiguration: pipConfig,
            ),
          ),
        // The app + the floating mini, covering the entire host area.
        Positioned.fill(child: floatingContainer),
        // Android: a listener-only widget that calls
        // `Overlay.of(context).insert(...)` when the OS triggers PiP. The
        // host sits above `MaterialApp`'s navigator (which owns the
        // navigator's Overlay), so a bare `StreamPictureInPictureAndroidView`
        // here has no `Overlay` ancestor and crashes with "No Overlay
        // widget found in context" the moment OS PiP fires. Wrap it in
        // a screen-sized `Overlay` so its own `Overlay.of(context)` call
        // resolves to this overlay; the SDK's PiP overlay entry then
        // inserts here and renders full-screen for the OS to capture.
        if (CurrentPlatform.isAndroid)
          Positioned.fill(
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (_) => StreamPictureInPictureAndroidView(
                    call: call,
                    configuration: pipConfig,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Both paths flip the controller out of `minimized` synchronously *before*
  /// dispatching the route push. The earlier design deferred the flip to the
  /// new `CallScreen.initState` (to avoid a one-frame gap where the mini
  /// disappeared before the route mounted) but proved fragile in apps with
  /// complex builder trees — nested navigators, go_router / auto_route
  /// delegates — where the remount-driven flip didn't reliably reach the
  /// host's listener and the mini persisted on top of the expanded call
  /// screen. Pre-flipping is reliable; the trade-off is a brief flash of the
  /// underlying app during the route's push animation. `CallScreen.initState`
  /// keeps its own flip as a defensive no-op for direct external mounts.
  ///
  /// The two paths:
  ///
  ///   1. **App-handled** — when [OitVideoCallHost.onExpandRequested] is
  ///      non-null, the host flips mode then invokes the callback so the
  ///      app pushes its own call route (auto_route / go_router) onto its
  ///      router stack. Apps using a custom router should always wire this
  ///      callback so the pushed route stays consistent with the router's
  ///      bookkeeping.
  ///   2. **Plugin-handled fallback** — host flips mode then pushes a
  ///      [MaterialPageRoute] onto the resolved navigator (preferring
  ///      [OitVideoCallHost.navigatorKey] when supplied, otherwise walking
  ///      the element tree). The pushed route rebuilds the call screen using
  ///      the args cached on [OitVideoCall.lastArgsOrNull].
  void _onExpandRequested(BuildContext context, ActiveCallController c) {
    // Flip mode synchronously in BOTH paths so the host's listener removes
    // the mini overlay regardless of whether the app's router or our
    // fallback ends up doing the push. Asymmetry here was the v1.2.6 bug:
    // pre-flipping only on the plugin-handled branch left app-handled
    // callers exposed to the same fragility.
    c.expand();
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
