# oit_video_call — Design Document

**Date:** 2026-04-27
**Status:** Approved, ready for implementation planning
**Repo:** github.com/Out-Of-India-Theory/video_call

## Goal

A shared Flutter package that wraps the Stream Video SDK so that both consumer
apps — `dharmayana_app` and `dharmayana_mitra_app` — can drop in 1:1 video (or
audio-only) consultations between a consultee and an astrologer using a
backend-provided call ID.

The plugin exists to:

1. Hide Stream's API behind a small, stable facade so the two host apps depend
   on the *plugin's* contract, not Stream's.
2. Stay neutral to the host apps' divergent stacks (dharmayana: Riverpod 2.x +
   AutoRoute + GetIt; mitra: Riverpod 3.x + go_router) by exposing only plain
   Flutter widgets and static methods — no providers, no router pages.
3. Centralize platform plumbing (Android manifest perms, runtime permission
   prompts, Stream client lifecycle) so both apps wire it up identically.

## Non-goals (v1)

- Push notifications / incoming-call ringing (CallKit / ConnectionService)
- Picture-in-picture, background calling
- Custom theming for the call UI (Stream's default look-and-feel ships as-is)
- Plugin-side localization of error strings (English only)
- Group calls, screen share, recording
- Web / desktop platforms — Android + iOS only

## Confirmed decisions

| Area | Decision |
|------|----------|
| SDK | Stream Video Flutter (`stream_video_flutter ^1.3.2`); re-exports `stream_video` so only one dependency declared |
| Plugin type | Pure Dart Flutter package (no platform channels of our own) |
| UI | Stream's pre-built `StreamCallContainer` — not a custom screen |
| API shape | Singleton facade: `OitVideoCall.init(...)` then `OitVideoCall.callScreen(callId, audioOnly)` |
| Lifecycle | Lazy connect: `init()` only stores config; `StreamVideo` is constructed when `callScreen` mounts and torn down on dispose |
| Call join | `call.get()` + `call.join(create: false)` — never creates; backend pre-creates the call |
| Audio-only | `audioOnly` flag on `callScreen`; when true, camera permission is skipped entirely and `setCameraEnabled(false)` after join |
| Permissions | Plugin handles runtime requests internally via `permission_handler`; host app only adds two iOS Info.plist strings |
| Errors | All errors render inside the call screen UI; no exceptions propagate out of plugin |
| Distribution | Git dependency, semver tags (e.g., `ref: v0.1.0`) |
| Package name | `oit_video_call` |
| Min platforms | Android `minSdkVersion 24`, iOS `13.0`, Dart SDK `>=3.8.0 <4.0.0` |
| State management | None — plain `StatefulWidget` internally; no Riverpod export |
| Routing | None — host app uses `MaterialPageRoute` (works in AutoRoute and go_router both) |

## Architecture

### Package layout

```
oit_video_call/
├── lib/
│   ├── oit_video_call.dart                # Public exports only
│   └── src/
│       ├── facade.dart                    # OitVideoCall static class
│       ├── config.dart                    # OitVideoCallConfig + VideoUser
│       ├── models/video_user.dart
│       ├── screen/call_screen.dart        # The only StatefulWidget
│       ├── screen/error_view.dart
│       └── errors.dart                    # OitVideoCallException, error codes
├── android/
│   ├── build.gradle                       # minSdk 24, kotlin
│   └── src/main/AndroidManifest.xml       # CAMERA, RECORD_AUDIO, BLUETOOTH_CONNECT, …
├── ios/                                   # (empty — no podspec needed)
├── example/                               # Demo app for QA / smoke testing
├── test/
├── analysis_options.yaml
├── CHANGELOG.md
├── LICENSE
├── README.md
└── pubspec.yaml
```

### Boundaries

- Host apps import only `package:oit_video_call/oit_video_call.dart`. They never
  touch Stream's types directly.
- `VideoUser` → `User.regular(...)` translation happens inside the facade.
- `OitVideoCallException` wraps any Stream/SDK errors so the host-app error
  shape is plugin-defined.
- The call screen is the only widget that constructs / disposes `StreamVideo`.

## Public API (the entire surface)

```dart
// lib/oit_video_call.dart
export 'src/facade.dart' show OitVideoCall;
export 'src/config.dart' show VideoUser;
export 'src/errors.dart' show OitVideoCallException, OitVideoCallErrorCode;
```

```dart
class OitVideoCall {
  /// Stores config; does not open a network connection.
  static Future<void> init({
    required String apiKey,
    required VideoUser user,
    required Future<String> Function() tokenProvider,
  });

  /// Returns a widget; push it with MaterialPageRoute.
  /// On mount: requests permissions → fetches token → constructs StreamVideo →
  ///   call.get() → call.join(create: false) → renders StreamCallContainer.
  /// On unmount: call.leave() + StreamVideo.reset().
  static Widget callScreen({
    required String callId,
    bool audioOnly = false,
    String callType = 'default',
    VoidCallback? onCallEnded,
  });

  /// Tears down the singleton. Idempotent.
  static Future<void> reset();

  static bool get isInitialized;
}

class VideoUser {
  final String id;
  final String name;
  final String? image;
  const VideoUser({required this.id, required this.name, this.image});
}

enum OitVideoCallErrorCode {
  notInitialized,
  permissionDenied,
  callNotFound,
  tokenFetchFailed,
  joinFailed,
  unknown,
}

class OitVideoCallException implements Exception {
  final OitVideoCallErrorCode code;
  final String message;
  final Object? cause;
}
```

### Host-app integration (identical for both apps)

```dart
// once at app startup
await OitVideoCall.init(
  apiKey: dotenv.env['STREAM_API_KEY']!,
  user: VideoUser(
    id: currentUser.id,
    name: currentUser.name,
    image: currentUser.avatarUrl,
  ),
  tokenProvider: () async {
    final res = await dio.get('/video/token');
    return res.data['token'] as String;
  },
);

// when starting a call
Navigator.push(context, MaterialPageRoute(
  builder: (_) => OitVideoCall.callScreen(
    callId: 'consult-abc',
    audioOnly: false,
  ),
));
```

## Internal flow — the call screen lifecycle

`_CallScreen` is the only `StatefulWidget` in the plugin. `initState` runs an
async setup with five sequential phases. Each phase can fail; failure flips
state to an error view and skips remaining phases.

```
phase 1   permissions  (mic always; camera only if !audioOnly)
            on permanent-deny  → error(permissionDenied, action: openSettings)
            on temp-deny       → error(permissionDenied, action: retry)
phase 2   await tokenProvider()
            on throw  → error(tokenFetchFailed)
phase 3   StreamVideo(apiKey, user: User.regular(...), userToken: token)
            on throw  → error(joinFailed)
phase 4   call = StreamVideo.instance.makeCall(callType, id);
          await call.get()
            on 404   → error(callNotFound)
            on other → error(joinFailed)
phase 5   await call.join(create: false)
          if audioOnly: await call.setCameraEnabled(false)
          state = ready(call) → render StreamCallContainer(call: call)
```

While in phases 1-5: spinner + "Joining call…" text. On error: `_ErrorView`
with the appropriate message and action button (Retry / Open Settings /
Close). Close calls `Navigator.maybePop(context)`.

`dispose()` runs unconditionally:

```dart
@override
void dispose() {
  _callEndedSub?.cancel();
  _call?.leave();              // idempotent
  StreamVideo.reset();         // tears down WebSocket, audio session, camera
  super.dispose();
}
```

A listener on `call.state` watches for `CallStatusDisconnected` and invokes
`widget.onCallEnded`. The plugin does **not** pop — pop semantics differ
between AutoRoute and go_router; host app handles it.

### Multi-instance guard

If `_CallScreen.initState` finds `StreamVideo._instance` non-null (host app
pushed `callScreen` while another is still mounted), it bails out with
`error(unknown, "Another call is already in progress")` rather than tearing
down the active call.

## Error handling — exhaustive matrix

| Scenario | Behavior |
|---|---|
| `callScreen` used before `init()` | Returns `_ErrorScreen(notInitialized)` immediately |
| Permission denied (temporary) | Error view with Retry button → re-runs phase 1 |
| Permission permanently denied | Error view with Open Settings button → `app_settings.openAppSettings()` |
| `tokenProvider` throws | Error view with Retry button → re-runs all phases |
| `StreamVideo` constructor throws | `error(joinFailed)` with Retry |
| `call.get()` returns 404 | `error(callNotFound)` — Retry available but unlikely to succeed; user typically pops |
| `call.join()` fails | `error(joinFailed)` with Retry |
| Token expires mid-call | Stream SDK invokes refresh hook → plugin re-invokes `tokenProvider` → continues. If refresh fails, `error(tokenFetchFailed)` |
| Network drops mid-call | Stream SDK auto-reconnects; pre-built UI shows reconnection state |
| Other party hangs up | `call.state` → `Disconnected` → `onCallEnded()` fires; host app pops |
| Host app calls `init()` twice | Second call replaces config — idempotent |
| Host app calls `reset()` mid-call | Mounted screen sees `Disconnected` → `onCallEnded()` |
| Host app pushes `callScreen` while another is mounted | New screen shows `error(unknown, "Another call already in progress")` |
| App backgrounded mid-call | No-op; Stream SDK handles short suspensions; PiP out of v1 scope |

### What never happens

`init()` and `callScreen()` never throw exceptions to the host app. All errors
are surfaced through the call screen UI. Host apps do not need try/catch.

### Logging

`dart:developer.log()` under `name: 'oit_video_call'`. No print, no logger
framework.

## Dependencies

```yaml
name: oit_video_call
description: OIT shared Flutter package wrapping Stream Video for Dharmayana apps.
version: 0.1.0
publish_to: 'none'

environment:
  sdk: '>=3.8.0 <4.0.0'
  flutter: '>=3.24.0'

dependencies:
  flutter: { sdk: flutter }
  stream_video_flutter: ^1.3.2     # transitively brings stream_video ^1.3.2
  permission_handler: ^11.3.1
  app_settings:                     # match dharmayana's git ref
    git: { url: https://github.com/spencerccf/app_settings.git, ref: master }

dev_dependencies:
  flutter_test: { sdk: flutter }
  flutter_lints: ^4.0.0
  mocktail: ^1.0.4
```

## Native configuration

### Android (auto-merged into host apps)

`android/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET" />
  <uses-permission android:name="android.permission.CAMERA" />
  <uses-permission android:name="android.permission.RECORD_AUDIO" />
  <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
  <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
  <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
  <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
  <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

  <uses-feature android:name="android.hardware.camera" android:required="false" />
  <uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
</manifest>
```

`android/build.gradle`: `minSdkVersion 24`.

### iOS (host apps must add — documented in README)

```xml
<key>NSCameraUsageDescription</key>
<string>Used for video consultations.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Used for audio during consultations.</string>
```

Plus `platform :ios, '13.0'` in each host app's Podfile.

## Testing strategy (v1)

Three unit-test files. No integration tests against real Stream backend.

1. **`facade_test.dart`** — pure Dart logic
   - `init()` populates internal config; `isInitialized` becomes true
   - `reset()` clears config
   - `callScreen()` before init renders `_ErrorScreen(notInitialized)` —
     verified via `tester.pumpWidget` and finding error text

2. **`models_test.dart`** — `VideoUser(id, name, image)` converts to
   `User.regular(userId: id, name: name, image: image)` correctly

3. **`screen_lifecycle_test.dart`** — phase progression with mocks
   - `permission_handler`: mock via standard `MethodChannel` overrides
   - `tokenProvider`: mock to return / throw
   - `StreamVideo`: not directly mockable — tested via a `StreamVideoFactory`
     dependency-injected into `_CallScreen` (private; only test code overrides
     it)
   - Verify state machine: spinner → ready, or spinner → error(code) for each
     failure mode

## `example/` app

Single-screen demo: text fields for call ID + audio-only checkbox + Join
button. Reads API key + token from `.env` via `flutter_dotenv` (dev only).
Lets you smoke-test against Stream's sandbox without touching either host app.
Lives under `example/` in the repo.

## Documentation

`README.md` covers:

- Add the git dependency (with tag-pinning recommendation)
- iOS Info.plist keys (copy-paste block)
- Android: nothing (manifest auto-merges)
- `init()` + `callScreen()` usage with examples for both host apps' startup
  points (`dharmayana`: `service_locator.dart`; `mitra`: `app.dart`)

## Versioning + release flow

- Semver tags (`v0.1.0`, `v0.1.1`, …)
- After every change worth pulling: push commit + create tag
- Both apps pin `ref: vX.Y.Z`, never `ref: main`

## Open questions for v2

- Custom theming layer (color/typography overrides for `StreamCallContainer`)
- Localization of plugin's own error strings
- Picture-in-picture support
- Push-triggered incoming call (ringing flow + CallKit / ConnectionService)
- Group calls
