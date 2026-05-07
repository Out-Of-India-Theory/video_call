# Changelog

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
