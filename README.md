# oit_video_call

Shared Flutter plugin wrapping [Stream Video](https://getstream.io/video/) for
Dharmayana apps. Provides 1:1 audio + video consultations against a
backend-provided call ID.

## Install

Add to the host app's `pubspec.yaml`:

```yaml
dependencies:
  oit_video_call:
    git:
      url: https://github.com/Out-Of-India-Theory/video_call.git
      ref: v1.0.0   # always pin a tag, not a branch
```

## iOS configuration

Add the following to the host app's `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Used for video consultations.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Used for audio during consultations.</string>
```

Set `platform :ios, '13.0'` in `ios/Podfile`.

## Android configuration

Nothing to do — the plugin's `AndroidManifest.xml` declares all required
permissions and they auto-merge into the host app. Host app must use
`minSdkVersion 24` or higher.

## Usage

```dart
import 'package:oit_video_call/oit_video_call.dart';

// Once at app startup
await OitVideoCall.init(
  apiKey: dotenv.env['STREAM_API_KEY']!,
  user: VideoUser(id: currentUser.id, name: currentUser.name, image: currentUser.avatarUrl),
  tokenProvider: () async {
    final res = await dio.get('/video/token');
    return res.data['token'] as String;
  },
);

// When starting a call
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => OitVideoCall.callScreen(
      callId: 'consult-abc',
      audioOnly: false,
    ),
  ),
);
```

## API

| Member | Description |
|---|---|
| `OitVideoCall.init(apiKey, user, tokenProvider)` | Stores config + builds the singleton controller. Does not connect. |
| `OitVideoCall.callScreen({callId, audioOnly, callType, createIfMissing, onCallEnded, confirmLeave})` | Returns the call-screen widget; push with `MaterialPageRoute`. Caches its args so the PiP host can rebuild on tap-to-expand. |
| `OitVideoCall.reset()` | Ends any active call, tears down the singleton, clears cached args. |
| `OitVideoCall.isInitialized` | Whether `init()` was called. |
| `OitVideoCallHost({child, minimizedBuilder?, onExpandRequested?})` | Wrap your `MaterialApp.builder` with this to enable in-app PiP. See "In-app Picture-in-Picture" below. |
| `ActiveCallController` (read-only via `OitVideoCall.controllerOrThrow`) | Exposes `state` (mode, callId, live `Call`) for apps that want to react to call lifecycle. |
| `ActiveCallMode`, `ActiveCallState` | State-machine types backing the controller. |
| `VideoUser(id, name, image)` | The signed-in user. |
| `OitVideoCallException`, `OitVideoCallErrorCode` | Error types — no exceptions cross the public API; all errors render inside the call screen. |

## Behavior

- The call screen handles permission requests internally.
- `audioOnly: true` skips camera permission and joins with the camera disabled.
- The call must already exist on Stream (created by your backend). The plugin
  never creates a call — it joins an existing one. If the call is missing,
  the screen renders a "Call not available" error.
- WebSocket opens on screen mount, closes on dispose. There is no persistent
  connection between calls.

## In-app Picture-in-Picture

Wrap your `MaterialApp` with `OitVideoCallHost` to enable the floating mini-window:

```dart
MaterialApp.router(
  builder: (ctx, child) => OitVideoCallHost(
    child: child!,
    // Optional — wire to your router when using auto_route / go_router:
    onExpandRequested: () => context.router.push(VideoCallRoute(callId: ...)),
  ),
  ...
)
```

Behavior:
- **Back press** while a call is connected → minimizes (no confirm).
- **End-Call** button → still triggers `confirmLeave`.
- **Tap** the mini view → expands back to full screen.
- The mini view shows **the remote participant only**.

### Routing integration

Apps using `auto_route` or `go_router` should always supply `onExpandRequested`:

```dart
OitVideoCallHost(
  child: child!,
  onExpandRequested: () => context.router.push(VideoCallRoute(callId: ...)),
)
```

The plugin-handled fallback (when `onExpandRequested` is null) pushes a
`MaterialPageRoute` onto the root Navigator using
`Navigator.of(context, rootNavigator: true)`. This works for plain
`MaterialApp` setups but may bypass your custom router's bookkeeping —
your router cannot pop or track the pushed route. Cupertino-styled apps
should also wire this callback to get iOS-style transitions, since the
fallback uses Material transitions only.

### Initialization order

Call `OitVideoCall.init(...)` **before** mounting `OitVideoCallHost`. The host
attaches its controller listener once in `initState`; later calls to `init()`
are not observed and the host will silently never show PiP.

### `confirmLeave` context lifetime

The `confirmLeave: (BuildContext context) => ...` closure is invoked from
multiple surfaces (the in-call End button, the back-press flow during
connecting, and — new in 1.1.0 — the mini-view End button). Always use the
`BuildContext` parameter rather than a captured context, since the closure may
be invoked from a different widget tree than the one that built
`OitVideoCall.callScreen(...)`.

## Out of scope (v1)

- Push notifications / incoming-call ringing
- Background calling (system-level PiP)
- Custom theming
- Group calls, screen share, recording
- Web / desktop platforms

## Demo

The `example/` app provides a smoke-test harness. Copy `.env.example` to
`.env`, fill in a Stream API key and a dev JWT, then `cd example && flutter run`.

## Versioning

Semver tags (`v1.0.0`, `v1.0.1`, …). Always pin a tag in host apps.
