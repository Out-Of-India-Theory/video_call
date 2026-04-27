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
| `OitVideoCall.init(...)` | Stores config; does not connect. |
| `OitVideoCall.callScreen({callId, audioOnly, callType, onCallEnded})` | Returns a widget; push with `MaterialPageRoute`. |
| `OitVideoCall.reset()` | Tears down the singleton. |
| `OitVideoCall.isInitialized` | Whether `init()` was called. |
| `VideoUser(id, name, image)` | The signed-in user. |
| `OitVideoCallException`, `OitVideoCallErrorCode` | Error types — though no exceptions cross the public API in v1; all errors render inside the call screen. |

## Behavior

- The call screen handles permission requests internally.
- `audioOnly: true` skips camera permission and joins with the camera disabled.
- The call must already exist on Stream (created by your backend). The plugin
  never creates a call — it joins an existing one. If the call is missing,
  the screen renders a "Call not available" error.
- WebSocket opens on screen mount, closes on dispose. There is no persistent
  connection between calls.

## Out of scope (v1)

- Push notifications / incoming-call ringing
- Picture-in-picture / background calling
- Custom theming
- Group calls, screen share, recording
- Web / desktop platforms

## Demo

The `example/` app provides a smoke-test harness. Copy `.env.example` to
`.env`, fill in a Stream API key and a dev JWT, then `cd example && flutter run`.

## Versioning

Semver tags (`v1.0.0`, `v1.0.1`, …). Always pin a tag in host apps.
