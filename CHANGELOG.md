# Changelog

## Unreleased

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
