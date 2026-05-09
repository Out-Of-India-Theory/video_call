# Changelog

## 1.3.1

- **fix**: OS-level Picture-in-Picture now fires when the app is
  backgrounded while the **in-app PiP** (mini view) is active.
  Previously the system PiP only worked while the full-screen call
  screen was on top — once the user pressed back to the mini, the
  `StreamCallContainer` was unmounted and with it Stream's platform
  PiP source views (`StreamPictureInPictureUiKitView` /
  `StreamPictureInPictureAndroidView`). Backgrounding the app from the
  mini just left the user on their home screen with no PiP. The host
  now re-mounts those platform views (sized + hidden behind the app
  for iOS, listener-only for Android) whenever the controller is
  `minimized` and has a live `Call`, so OS PiP works in both states.

## 1.3.0

- **feat**: `ActiveCallController.endCall({bool forEveryone = false})`. When
  `forEveryone: true`, the host attempts to terminate the call for **all**
  participants on the Stream coordinator (via `Call.end()`) rather than
  just leaving. Falls back to a plain leave if the server rejects the
  end-for-all request (typically a permission issue) so the local user is
  always out regardless. Default `false` preserves the original "leave only"
  behavior for back-press / mini-End / natural-disconnect paths.
- **feat**: `OitVideoCall.endCall({bool forEveryone = false})` static
  facade method. Apps can call this directly without reaching across the
  controller boundary, mirroring `OitVideoCall.reset()` etc.
- **feat (CallSession)**: New `endCallForEveryone(Call)` abstract method on
  the test seam. `StreamCallSession` implements it via `Call.end()`;
  `FakeCallSession` adds `endForEveryoneCount` + `endForEveryoneError` +
  `disposeError`.
- **fix**: `endCall()` now wraps `_session.dispose()` in try/catch (was
  the only un-wrapped call in the teardown chain). Hosts can now `await
  endCall()` without try/catch — no error path bubbles out to the app.
- Three new lifecycle tests cover the happy path (room terminated,
  leaveCall not called), the fallback path (`Call.end()` throws →
  `leaveCall` runs), and the dispose-error path (StreamVideo.reset
  throws → endCall returns idle without re-throwing).

Use case: the mitra app's order-completion flow can now drop both the
astrologer's and the customer's connections in one step via
`OitVideoCall.endCall(forEveryone: true)`. Apps that don't opt in are
unaffected.

## 1.2.9

- **revert**: Drop the dynamic `floatingViewPadding` heuristic added in
  v1.2.8. Apps wiring the host through `MaterialApp.builder` already see
  a safe-area-aware container (the Scaffold's `SafeArea` and Material
  chrome consume system insets before the FloatingViewContainer measures),
  so adding `viewPadding.bottom + 8` on top noticeably shifted the mini
  toward the screen center. Padding now defaults to Stream's 16dp.

## 1.2.8

- **change**: Mini PiP now starts in the **bottom-right** corner instead of
  top-right. Better match for the consumer / mitra UX expectation, and
  keeps the floating window clear of the AppBar. The floating window is
  still draggable and snaps to the nearest corner on release; this only
  changes the initial corner.
- **fix**: `floatingViewPadding` is now computed from `MediaQuery.viewPadding`
  (`max(16, largestInset + 8)`) instead of a hard-coded 16dp. Stream's
  `FloatingViewContainer` uses a single padding value for all corners and
  doesn't account for safe-area insets, so the previous 16dp default
  caused the bottom-right corner to overlap with the gesture-navigation
  indicator on Pixel / iPhone devices. The dynamic value clears the
  system gesture / status-bar areas at every corner without affecting
  3-button-nav devices (where `viewPadding.bottom == 0`, falling back to
  the 16dp minimum).

## 1.2.7

- **fix**: Pre-flip from v1.2.6 is now symmetric — applied in both the
  app-handled (`onExpandRequested`) AND plugin-handled branches of
  `_onExpandRequested`. The earlier asymmetry left apps wiring
  `onExpandRequested` (auto_route / go_router users — the recommended
  router-aware path) exposed to the same mini-stays-on-top fragility that
  motivated v1.2.6. New widget test asserts the synchronous flip on the
  app-handled path.
- **docs**: Updated the `_onExpandRequested` dartdoc to describe the new
  pre-flip behavior accurately. Earlier wording still claimed "the host does
  not call `c.expand()` directly" — stale since v1.2.6.

## 1.2.6

- **fix**: Plugin-handled tap-to-expand now flips the controller out of
  `minimized` mode synchronously inside the host's `_onExpandRequested`,
  before pushing the call-screen route. The previous design deferred the
  flip to the new `CallScreen.initState` (to avoid a one-frame gap). In
  apps with complex builder trees (nested navigators / go_router /
  auto_route delegates) the remount-driven flip didn't always propagate
  to the host's listener, leaving the mini overlay on top of the expanded
  call screen. Pre-flipping is reliable; the trade-off is a brief flash
  of the underlying app during the route push animation. The init-state
  flip remains in place as a no-op fallback for the
  `OitVideoCallHost.onExpandRequested` (app-handled) path.

## 1.2.5

- **feat**: `OitVideoCallHost` accepts an optional `navigatorKey` parameter.
  Pass the same key you hand to `MaterialApp.navigatorKey` /
  `MaterialApp.router`'s router-delegate to skip the down-tree walk used by
  the v1.2.4 fix. Strongly recommended in production apps — the down-tree
  walk is best-effort and can pick the wrong navigator in
  multi-`MaterialApp` / add-to-app embeddings.
- **fix**: When no Navigator can be reached, the mini End button now aborts
  silently instead of falling through to `endCall()`. Silently terminating a
  live consultation because of a transient lookup miss is a worse default
  than a no-op (the user can re-tap once the navigator is mounted).
- **test**: Added three regression tests that wire `OitVideoCallHost`
  through `MaterialApp.builder` (the actual bug surface): builder-wired
  `confirmLeave` receives a Navigator-rooted context; `navigatorKey` takes
  precedence over the tree walk; abort path leaves the call alive.

## 1.2.4

- **fix**: Mini view's End and Fullscreen buttons now work in apps that wire
  `OitVideoCallHost` through `MaterialApp.builder` (which is the documented
  pattern). The host's `BuildContext` sits *above* the app's Navigator there,
  so `Navigator.of(context, rootNavigator: true)` walked up and found
  nothing — pushes and `showModalBottomSheet` (used by `confirmLeave`)
  silently no-op'd. Host now walks DOWN from `WidgetsBinding.rootElement` to
  find the topmost `NavigatorState` and uses its overlay context for the
  confirm prompt and its own `push` for tap-to-expand. Mic was unaffected
  because it talks straight to `Call.setMicrophoneEnabled`.

## 1.2.3

- **change**: `MinimizedCallView` now picks the participant to render via a
  three-step fallback: **remote-dominant-speaker → first-remote →
  first-of-any**. Local-dominant is intentionally ignored so 1:1 consultation
  tiles don't flip to self-view when the local user is talking. Solo /
  pre-join sessions still see their own tile (covered by the final
  fallback). Selector logic is extracted as a `@visibleForTesting`
  `pickMinimizedParticipant` and unit-tested across solo, 1:1 (peer-silent,
  local-dominant, remote-dominant), and multi-party scenarios.

## 1.2.2

- **fix**: `ActiveCallController.connectAndJoin` Phase 5 catch now best-effort
  `leaveCall` + `dispose` before returning `ConnectErrored(joinFailed)`. A
  `setCameraEnabled` failure after a successful `joinCall` was previously
  leaking the live SDK call.
- **fix**: `connectAndJoin` no longer throws `StateError` synchronously when
  re-entered with a different `callId`. It now returns
  `ConnectErrored(unknown, ...)` so the screen renders the error UI instead
  of the fire-and-forget `_start()` future hanging the loading spinner.
- **fix**: `endCall()` short-circuits when mode is already `ending` (not just
  `idle`). Concurrent invocations (e.g. mini End tap + host lifecycle
  observer) no longer run `leaveCall`/`dispose` twice in parallel.
- **change**: `MinimizedCallView` constructor params are now non-nullable
  (`controller`, `onExpand`, `onEnd`); the `placeholderForTest` constructor
  is removed. The "Connecting…" placeholder is still rendered when
  `controller.state.call` is null. Callers passing `null` will now fail at
  compile time instead of silently rendering the disabled mini.
- **fix**: Mini mic button passes the latest visual `isOn` from
  `PartialCallStateBuilder`'s closure into `_toggleMic` instead of re-reading
  `call.state.value` synchronously. Two rapid taps on a stale-icon view now
  both act on the same value (intent: mute) and the SDK serializes them.

## 1.2.1

- **fix**: `OitVideoCallHost` now attaches lazily via
  `OitVideoCall.activeControllerListenable`. Apps can call `OitVideoCall.init`
  AFTER mounting the host (e.g. lazily on the first "Join Call" tap once the
  user profile is loaded) and the host will hook up correctly. Previously the
  host only attached if init had already run by `initState` time.

## 1.2.0

- **feat**: in-app Picture-in-Picture. Wrap `MaterialApp` with `OitVideoCallHost`.
  Floating mini-window with corner-snap (built on Stream's
  `FloatingViewContainer`), reactive mic icon, end / expand controls,
  remote-participant-only video, auto-dismiss on natural disconnect, and
  `fastReconnecting` ↔ `connected` mode tracking.
- **change**: Back press while connected now minimizes instead of triggering `confirmLeave`. End-Call button still uses `confirmLeave`.
- **refactor**: call lifecycle moved out of `CallScreen` into `ActiveCallController` so it survives `Navigator.pop`.
- Phase 1 permission denial now always shows "Open Settings" (Retry is gone).
  Retry was unreliable cross-platform: iOS returns "denied" immediately on
  subsequent `request()` calls without re-prompting, and on Android once the
  user hits "Don't ask again" Retry stops working. Settings always works.
  The denial message also now says "Microphone" vs "Camera and microphone"
  based on the `audioOnly` flag.
- Add `createIfMissing` flag to `OitVideoCall.callScreen`. When `true`, the
  call screen calls `Stream`'s `call.getOrCreate()` instead of `call.get()`,
  enabling first-joiner-creates semantics. Default `false` preserves existing
  strict-join behavior.
- Add `CallSession.getOrCreateCall` to support the above. `StreamCallSession`
  delegates to the real Stream API; `FakeCallSession` (test only) gains a
  matching counter and failure flag.

## 1.0.0 — 2026-04-28

- Initial release.
- 1:1 audio + video calling against an existing Stream call ID.
- Static facade `OitVideoCall.init` + `OitVideoCall.callScreen`.
- Auto-handles Android manifest permissions and runtime permission requests.
