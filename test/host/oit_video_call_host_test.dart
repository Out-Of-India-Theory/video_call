import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/oit_video_call.dart';
import 'package:oit_video_call/src/config.dart';

import '../screen/fake_call_session.dart';

OitVideoCallConfig _config() => OitVideoCallConfig(
      apiKey: 'k',
      user: const VideoUser(id: 'u', name: 'U'),
      tokenProvider: () async => 't',
    );

/// Builds an [ActiveCallController] backed by [FakeCallSession], wires it
/// into the [OitVideoCall] singleton via the test-only injection seam, and
/// flips it into `minimized` mode (with a null `Call`) so the host's overlay
/// is active when we pump but neither the video nor the mic builder reaches
/// a mocked Stream [Call].
ActiveCallController _setupSingletonInMinimized({
  required FakeCallSession session,
  Future<bool> Function(BuildContext)? confirmLeave,
}) {
  final controller = ActiveCallController(session: session);
  OitVideoCall.initForTest(config: _config(), controller: controller);

  // Cache args so the host's `_onEndRequested` can read `confirmLeave`. The
  // returned widget is intentionally unused: only the side effect of
  // populating `lastArgsOrNull` matters here.
  OitVideoCall.callScreen(
    callId: 'c1',
    callType: 'default',
    confirmLeave: confirmLeave,
  );

  // Flip directly into `minimized` without a live Call so the mini's video
  // and mic builders fall into the placeholder branches.
  controller.forceMinimizedForTest(callId: 'c1', callType: 'default');
  expect(controller.state.mode, ActiveCallMode.minimized);
  expect(controller.state.call, isNull);
  return controller;
}

void main() {
  setUp(() async {
    await OitVideoCall.reset();
  });

  testWidgets(
    'mini End cancels when confirmLeave returns false (call NOT ended)',
    (tester) async {
      final session = FakeCallSession();
      var confirmCalls = 0;
      final controller = _setupSingletonInMinimized(
        session: session,
        confirmLeave: (_) async {
          confirmCalls++;
          return false;
        },
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: OitVideoCallHost(child: SizedBox.expand()),
        ),
      );
      await tester.pump();

      final endIcon = find.byIcon(Icons.call_end);
      expect(endIcon, findsOneWidget);

      await tester.tap(endIcon);
      // Allow the awaited `confirmLeave` future to resolve.
      await tester.pump();
      await tester.pump();

      // confirmLeave was consulted but rejected the leave — the controller
      // must still be `minimized` and the session untouched (no leave/dispose).
      expect(confirmCalls, 1);
      expect(controller.state.mode, ActiveCallMode.minimized);
      expect(session.leaveCount, 0);
      expect(session.disposeCount, 0);
    },
  );

  testWidgets(
    'mini End ends the call when confirmLeave returns true',
    (tester) async {
      final session = FakeCallSession();
      var confirmCalls = 0;
      final controller = _setupSingletonInMinimized(
        session: session,
        confirmLeave: (_) async {
          confirmCalls++;
          return true;
        },
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: OitVideoCallHost(child: SizedBox.expand()),
        ),
      );
      await tester.pump();

      final endIcon = find.byIcon(Icons.call_end);
      expect(endIcon, findsOneWidget);

      await tester.tap(endIcon);
      // endCall awaits leave + dispose on the fake session — pump until idle.
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(confirmCalls, 1);
      expect(controller.state.mode, ActiveCallMode.idle);
      // No live Call was ever attached (we flipped straight into minimized
      // via the debug helper) so there is nothing to leave; the session is
      // still disposed.
      expect(session.leaveCount, 0);
      expect(session.disposeCount, 1);
    },
  );

  testWidgets(
    'mini End ends the call directly when no confirmLeave is wired',
    (tester) async {
      final session = FakeCallSession();
      // Pass null to preserve the historical "tap End → call ends" behavior
      // for hosts that haven't opted into a confirmation dialog.
      final controller = _setupSingletonInMinimized(
        session: session,
        confirmLeave: null,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: OitVideoCallHost(child: SizedBox.expand()),
        ),
      );
      await tester.pump();

      final endIcon = find.byIcon(Icons.call_end);
      expect(endIcon, findsOneWidget);

      await tester.tap(endIcon);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(controller.state.mode, ActiveCallMode.idle);
      expect(session.disposeCount, 1);
    },
  );

  // -------------------------------------------------------------------
  // Regression tests for the host's Navigator-resolution path. The bug
  // surface is the documented integration pattern: `OitVideoCallHost`
  // wired through `MaterialApp.builder`. Earlier tests use `home:` which
  // puts the host BELOW the Navigator (Navigator.of(host.context) walks
  // up and finds it) — exactly the path that worked before the v1.2.4
  // fix. The tests below put the host ABOVE the Navigator (via builder),
  // matching how production apps wire it.
  // -------------------------------------------------------------------

  testWidgets(
    'builder-wired host: tap Fullscreen flips controller out of minimized synchronously',
    (tester) async {
      // Regression check for the v1.2.6 fix. Earlier versions deferred the
      // mode flip to the new `CallScreen.initState`. Apps with complex
      // builder trees (nested navigators, custom router delegates) saw the
      // mini stay visible on top of the expanded call screen because the
      // remount-driven flip never propagated to the host's listener. The
      // host now flips mode itself in `_onExpandRequested` so the mini is
      // removed in the same frame as the route push.
      final session = FakeCallSession();
      final controller = _setupSingletonInMinimized(session: session);

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => OitVideoCallHost(child: child!),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      await tester.pump();

      expect(controller.state.mode, ActiveCallMode.minimized);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);

      await tester.tap(find.byIcon(Icons.fullscreen));
      // No pump yet — the flip must be synchronous, not deferred to a
      // post-mount callback. The host's listener removes the mini overlay
      // on the next rebuild.
      expect(
        controller.state.mode,
        ActiveCallMode.connected,
        reason: 'host must flip mode synchronously when tap-to-expand fires '
            'so the mini disappears even if the new route\'s '
            'CallScreen.initState never runs the fallback flip',
      );
    },
  );

  testWidgets(
    'builder-wired host: tap Fullscreen with onExpandRequested also flips synchronously',
    (tester) async {
      // Symmetric check for the v1.2.7 fix. Earlier versions only pre-flipped
      // on the plugin-handled branch; apps wiring `onExpandRequested` (the
      // recommended path for go_router / auto_route) hit the same
      // mini-stays-on-top regression because the host invoked their callback
      // and bailed without flipping. The host now flips in BOTH branches.
      final session = FakeCallSession();
      final controller = _setupSingletonInMinimized(session: session);

      var callbackCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => OitVideoCallHost(
            onExpandRequested: () => callbackCalls++,
            child: child!,
          ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      await tester.pump();

      expect(controller.state.mode, ActiveCallMode.minimized);

      await tester.tap(find.byIcon(Icons.fullscreen));
      // No pump — the flip must be synchronous so the host's listener
      // removes the mini before the next frame, regardless of when (or
      // whether) the app's callback eventually pushes a route.
      expect(callbackCalls, 1);
      expect(
        controller.state.mode,
        ActiveCallMode.connected,
        reason: 'host must flip mode synchronously even when delegating the '
            'route push to onExpandRequested',
      );
    },
  );

  testWidgets(
    'builder-wired host: tap End passes a Navigator-rooted context to confirmLeave',
    (tester) async {
      BuildContext? receivedContext;
      final session = FakeCallSession();
      _setupSingletonInMinimized(
        session: session,
        confirmLeave: (ctx) async {
          receivedContext = ctx;
          return false; // skip the endCall path so the test stays focused
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => OitVideoCallHost(child: child!),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.call_end), findsOneWidget);
      await tester.tap(find.byIcon(Icons.call_end));
      await tester.pump();
      await tester.pump();

      expect(receivedContext, isNotNull,
          reason: 'confirmLeave should have been invoked');
      // The actual regression check: the context handed to confirmLeave must
      // resolve a Navigator ancestor, so `showModalBottomSheet(context: ...)`
      // (used by the consumer / mitra `confirmLeave` implementations) works.
      expect(
        Navigator.maybeOf(receivedContext!),
        isNotNull,
        reason: 'context passed to confirmLeave must have a Navigator '
            'ancestor — pre-fix this returned null and showModalBottomSheet '
            'silently failed',
      );
    },
  );

  testWidgets(
    'builder-wired host: navigatorKey is preferred over tree-walk fallback',
    (tester) async {
      BuildContext? receivedContext;
      final session = FakeCallSession();
      _setupSingletonInMinimized(
        session: session,
        confirmLeave: (ctx) async {
          receivedContext = ctx;
          return false;
        },
      );

      final navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          builder: (_, child) => OitVideoCallHost(
            navigatorKey: navKey,
            child: child!,
          ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.call_end));
      await tester.pump();
      await tester.pump();

      expect(receivedContext, isNotNull);
      expect(
        Navigator.of(receivedContext!),
        same(navKey.currentState),
        reason: 'when navigatorKey is supplied, the host must scope the '
            'confirm prompt to that navigator instead of walking the element '
            'tree',
      );
    },
  );

  testWidgets(
    'no Navigator reachable: End aborts without ending or invoking confirmLeave',
    (tester) async {
      var confirmCalled = false;
      final session = FakeCallSession();
      final controller = _setupSingletonInMinimized(
        session: session,
        confirmLeave: (_) async {
          confirmCalled = true;
          return true;
        },
      );

      // No MaterialApp → no Navigator anywhere in the tree. Exercises the
      // abort branch in `_onEndRequested` where `_resolveNavigator()` returns
      // null. The host must NOT silently end the call (worse default than a
      // no-op) and NOT invoke confirmLeave (it would crash on
      // `showModalBottomSheet` without a Navigator).
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: OitVideoCallHost(child: SizedBox.expand()),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.call_end));
      await tester.pump();
      await tester.pump();

      expect(confirmCalled, isFalse,
          reason: 'confirmLeave must not be invoked without a Navigator');
      expect(controller.state.mode, ActiveCallMode.minimized,
          reason: 'call must stay alive — silently ending without '
              'confirmation is worse than the user re-tapping later');
      expect(session.disposeCount, 0);
    },
  );
}
