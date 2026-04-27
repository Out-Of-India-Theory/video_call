# oit_video_call Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Branch:** `release/1.0.0` — first release tagged `v1.0.0`.

**Goal:** Build `oit_video_call`, a shared Flutter plugin that wraps `stream_video_flutter` and ships a single import surface for both `dharmayana_app` and `dharmayana_mitra_app` to add 1:1 audio/video consultations.

**Architecture:** Pure facade plugin. `OitVideoCall.init(...)` stores config (no network). `OitVideoCall.callScreen(callId, audioOnly)` returns a self-contained widget that walks a 5-phase setup (permissions → token → StreamVideo construct → call.get → call.join), then renders Stream's pre-built `StreamCallContainer`. Lifecycle is screen-scoped: WebSocket opens on mount, tears down on dispose. Internal `_CallSession` abstraction allows full unit testing without a Stream backend.

**Tech Stack:** Flutter (Dart 3.8+), `stream_video_flutter ^1.3.2`, `permission_handler ^11.3.1`, `app_settings`, `mocktail` for tests.

**Reference:** [Approved design doc](./2026-04-27-oit-video-call-plugin-design.md) — read this first if any task feels ambiguous.

---

## Notes for the implementing engineer

- Working directory for ALL tasks: `/Users/prabhatpatel/development/Github/video_call`
- The repo has exactly one commit (the design doc). Every task below is a fresh commit.
- Commit messages follow `type: description` (e.g., `feat:`, `chore:`, `test:`). No Co-Authored-By trailer.
- Do NOT push to remote until the user explicitly asks. Local commits only.
- We're using `--template=plugin` (not `package`) so the plugin's `AndroidManifest.xml` auto-merges into host apps. The native iOS/Android stubs that Flutter scaffolds will be left untouched — we don't add native code.
- Stream's `stream_video_flutter` re-exports `stream_video`, so we never import `package:stream_video/...` directly — only `package:stream_video_flutter/stream_video_flutter.dart`.
- Use TDD where tests give meaningful coverage. For real-Stream-API integration (phases 3-5 of the call screen), we use a `_CallSession` abstraction that is faked in tests — real network calls are smoke-tested via the example app, not unit tests.
- Refer to `@docs/plans/2026-04-27-oit-video-call-plugin-design.md` if you ever need to confirm a design decision.

---

## Phase A — Scaffolding (no TDD; setup only)

### Task 1: Scaffold the Flutter plugin

**Files:**
- Create: entire `lib/`, `android/`, `ios/`, `pubspec.yaml`, `.gitignore`, `analysis_options.yaml`, etc. via `flutter create`

**Step 1: Run flutter create in-place**

Run:
```bash
cd /Users/prabhatpatel/development/Github/video_call
flutter create --template=plugin --platforms=android,ios --org in.dharmayana --project-name oit_video_call .
```

Expected output: lists files created (lib/oit_video_call.dart, android/, ios/, etc.). The `docs/` directory and `.git/` are preserved.

**Step 2: Verify scaffold**

Run: `ls -la lib/ android/src/main/ ios/Classes/`
Expected: `lib/oit_video_call.dart`, `android/src/main/AndroidManifest.xml`, `ios/Classes/OitVideoCallPlugin.swift` exist.

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: scaffold flutter plugin via flutter create"
```

---

### Task 2: Replace pubspec.yaml with our deps

**Files:**
- Modify: `pubspec.yaml`

**Step 1: Overwrite pubspec.yaml**

Replace entire file contents with:

```yaml
name: oit_video_call
description: OIT shared Flutter plugin wrapping Stream Video for Dharmayana apps.
version: 1.0.0
publish_to: 'none'

environment:
  sdk: '>=3.8.0 <4.0.0'
  flutter: '>=3.24.0'

dependencies:
  flutter:
    sdk: flutter
  stream_video_flutter: ^1.3.2
  permission_handler: ^11.3.1
  app_settings:
    git:
      url: https://github.com/spencerccf/app_settings.git
      ref: master

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  mocktail: ^1.0.4

flutter:
  plugin:
    platforms:
      android:
        package: in.dharmayana.oit_video_call
        pluginClass: OitVideoCallPlugin
      ios:
        pluginClass: OitVideoCallPlugin
```

**Step 2: Resolve deps**

Run: `flutter pub get`
Expected: "Got dependencies!" with no errors.

**Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: configure plugin pubspec with stream_video_flutter and deps"
```

---

### Task 3: Update Android manifest with required permissions

**Files:**
- Modify: `android/src/main/AndroidManifest.xml`

**Step 1: Replace AndroidManifest.xml**

Replace entire contents with:

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

**Step 2: Commit**

```bash
git add android/src/main/AndroidManifest.xml
git commit -m "chore(android): declare camera, mic, and bluetooth permissions"
```

---

### Task 4: Set Android minSdk to 24

**Files:**
- Modify: `android/build.gradle`

**Step 1: Read the current Gradle file**

Run: `cat android/build.gradle | grep -n -i 'minsdk\|defaultConfig'`
Note: Recent `flutter create` versions may already set `minSdkVersion 21` or use the project's default.

**Step 2: Ensure minSdkVersion 24**

Open `android/build.gradle`. Inside `android { defaultConfig { ... } }`, set:

```groovy
defaultConfig {
    minSdkVersion 24
    // (other lines unchanged)
}
```

If the file uses `flutter.minSdkVersion`, override it as above with the literal `24`.

**Step 3: Commit**

```bash
git add android/build.gradle
git commit -m "chore(android): set minSdkVersion to 24 (Stream Video requirement)"
```

---

### Task 5: Configure analysis_options.yaml

**Files:**
- Modify: `analysis_options.yaml`

**Step 1: Replace contents**

```yaml
include: package:flutter_lints/flutter.yaml

analyzer:
  exclude:
    - "**/*.g.dart"
    - "**/*.freezed.dart"
  errors:
    invalid_annotation_target: ignore

linter:
  rules:
    - prefer_single_quotes
    - prefer_const_constructors
    - prefer_const_literals_to_create_immutables
    - require_trailing_commas
    - avoid_print
```

**Step 2: Run analyzer to confirm clean baseline**

Run: `dart analyze`
Expected: no issues reported (the scaffolded `lib/oit_video_call.dart` is clean).

**Step 3: Commit**

```bash
git add analysis_options.yaml
git commit -m "chore: configure analyzer with flutter_lints"
```

---

### Task 6: Add LICENSE and CHANGELOG skeleton

**Files:**
- Create: `LICENSE`, `CHANGELOG.md`

**Step 1: Add LICENSE**

Match the OIT convention (likely MIT) — copy from `dharmayana_mitra_app/LICENSE` if it exists; otherwise:

```bash
cp /Users/prabhatpatel/development/Github/dharmayana_mitra_app/LICENSE ./LICENSE 2>/dev/null || cat > LICENSE <<'EOF'
MIT License

Copyright (c) 2026 Out of India Theory

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
```

**Step 2: Add CHANGELOG.md**

```markdown
# Changelog

## 1.0.0 — Unreleased

- Initial release.
- 1:1 audio + video calling against an existing Stream call ID.
- Static facade `OitVideoCall.init` + `OitVideoCall.callScreen`.
- Auto-handles Android manifest permissions and runtime permission requests.
```

**Step 3: Commit**

```bash
git add LICENSE CHANGELOG.md
git commit -m "chore: add LICENSE and CHANGELOG skeleton"
```

---

## Phase B — Public types (TDD)

### Task 7: VideoUser

**Files:**
- Create: `lib/src/models/video_user.dart`
- Create: `test/models/video_user_test.dart`

**Step 1: Write the failing test**

Create `test/models/video_user_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/models/video_user.dart';

void main() {
  group('VideoUser', () {
    test('stores id, name, and optional image', () {
      const user = VideoUser(id: 'u1', name: 'Foo', image: 'https://x/y.png');
      expect(user.id, 'u1');
      expect(user.name, 'Foo');
      expect(user.image, 'https://x/y.png');
    });

    test('image is null by default', () {
      const user = VideoUser(id: 'u1', name: 'Foo');
      expect(user.image, isNull);
    });

    test('two VideoUsers with same fields are equal', () {
      const a = VideoUser(id: 'u1', name: 'Foo');
      const b = VideoUser(id: 'u1', name: 'Foo');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
```

**Step 2: Run test (expect failure)**

Run: `flutter test test/models/video_user_test.dart`
Expected: FAIL — `lib/src/models/video_user.dart` does not exist.

**Step 3: Implement**

Create `lib/src/models/video_user.dart`:

```dart
class VideoUser {
  const VideoUser({required this.id, required this.name, this.image});

  final String id;
  final String name;
  final String? image;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoUser &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          image == other.image;

  @override
  int get hashCode => Object.hash(id, name, image);
}
```

**Step 4: Run test (expect pass)**

Run: `flutter test test/models/video_user_test.dart`
Expected: 3 tests passing.

**Step 5: Commit**

```bash
git add lib/src/models/video_user.dart test/models/video_user_test.dart
git commit -m "feat: add VideoUser model"
```

---

### Task 8: OitVideoCallException + error codes

**Files:**
- Create: `lib/src/errors.dart`
- Create: `test/errors_test.dart`

**Step 1: Write the failing test**

Create `test/errors_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/errors.dart';

void main() {
  group('OitVideoCallException', () {
    test('exposes code, message, and optional cause', () {
      final cause = Exception('boom');
      final ex = OitVideoCallException(
        code: OitVideoCallErrorCode.joinFailed,
        message: 'could not join',
        cause: cause,
      );
      expect(ex.code, OitVideoCallErrorCode.joinFailed);
      expect(ex.message, 'could not join');
      expect(ex.cause, cause);
    });

    test('toString includes code and message', () {
      const ex = OitVideoCallException(
        code: OitVideoCallErrorCode.callNotFound,
        message: 'no such call',
      );
      expect(ex.toString(), contains('callNotFound'));
      expect(ex.toString(), contains('no such call'));
    });
  });

  test('OitVideoCallErrorCode enumerates all expected codes', () {
    expect(
      OitVideoCallErrorCode.values.toSet(),
      {
        OitVideoCallErrorCode.notInitialized,
        OitVideoCallErrorCode.permissionDenied,
        OitVideoCallErrorCode.callNotFound,
        OitVideoCallErrorCode.tokenFetchFailed,
        OitVideoCallErrorCode.joinFailed,
        OitVideoCallErrorCode.unknown,
      },
    );
  });
}
```

**Step 2: Run test (expect failure)**

Run: `flutter test test/errors_test.dart`
Expected: FAIL — file not found.

**Step 3: Implement**

Create `lib/src/errors.dart`:

```dart
enum OitVideoCallErrorCode {
  notInitialized,
  permissionDenied,
  callNotFound,
  tokenFetchFailed,
  joinFailed,
  unknown,
}

class OitVideoCallException implements Exception {
  const OitVideoCallException({
    required this.code,
    required this.message,
    this.cause,
  });

  final OitVideoCallErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'OitVideoCallException(${code.name}): $message';
}
```

**Step 4: Run test (expect pass)**

Run: `flutter test test/errors_test.dart`
Expected: all tests passing.

**Step 5: Commit**

```bash
git add lib/src/errors.dart test/errors_test.dart
git commit -m "feat: add OitVideoCallException and error codes"
```

---

## Phase C — Internal config (TDD)

### Task 9: OitVideoCallConfig

**Files:**
- Create: `lib/src/config.dart`
- Create: `test/config_test.dart`

**Step 1: Write the failing test**

Create `test/config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/models/video_user.dart';

void main() {
  test('OitVideoCallConfig holds api key, user, and tokenProvider', () async {
    Future<String> tokenProvider() async => 'jwt-123';

    final config = OitVideoCallConfig(
      apiKey: 'key',
      user: const VideoUser(id: 'u1', name: 'Foo'),
      tokenProvider: tokenProvider,
    );

    expect(config.apiKey, 'key');
    expect(config.user.id, 'u1');
    expect(await config.tokenProvider(), 'jwt-123');
  });
}
```

**Step 2: Run test (expect failure)**

Run: `flutter test test/config_test.dart`
Expected: FAIL — file not found.

**Step 3: Implement**

Create `lib/src/config.dart`:

```dart
import 'models/video_user.dart';

typedef TokenProvider = Future<String> Function();

class OitVideoCallConfig {
  const OitVideoCallConfig({
    required this.apiKey,
    required this.user,
    required this.tokenProvider,
  });

  final String apiKey;
  final VideoUser user;
  final TokenProvider tokenProvider;
}
```

**Step 4: Run test (expect pass)**

Run: `flutter test test/config_test.dart`
Expected: pass.

**Step 5: Commit**

```bash
git add lib/src/config.dart test/config_test.dart
git commit -m "feat: add OitVideoCallConfig"
```

---

## Phase D — Facade (TDD)

### Task 10: OitVideoCall.init / isInitialized / reset

**Files:**
- Create: `lib/src/facade.dart`
- Create: `test/facade_test.dart`

**Step 1: Write the failing test**

Create `test/facade_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/facade.dart';
import 'package:oit_video_call/src/models/video_user.dart';

void main() {
  setUp(() async {
    // Ensure a clean slate between tests.
    await OitVideoCall.reset();
  });

  group('OitVideoCall lifecycle', () {
    test('isInitialized is false before init', () {
      expect(OitVideoCall.isInitialized, isFalse);
    });

    test('isInitialized becomes true after init', () async {
      await OitVideoCall.init(
        apiKey: 'key',
        user: const VideoUser(id: 'u1', name: 'Foo'),
        tokenProvider: () async => 'jwt',
      );
      expect(OitVideoCall.isInitialized, isTrue);
    });

    test('reset clears initialization', () async {
      await OitVideoCall.init(
        apiKey: 'key',
        user: const VideoUser(id: 'u1', name: 'Foo'),
        tokenProvider: () async => 'jwt',
      );
      await OitVideoCall.reset();
      expect(OitVideoCall.isInitialized, isFalse);
    });

    test('init can be called twice (idempotent replace)', () async {
      await OitVideoCall.init(
        apiKey: 'k1',
        user: const VideoUser(id: 'u1', name: 'A'),
        tokenProvider: () async => 't1',
      );
      await OitVideoCall.init(
        apiKey: 'k2',
        user: const VideoUser(id: 'u2', name: 'B'),
        tokenProvider: () async => 't2',
      );
      expect(OitVideoCall.isInitialized, isTrue);
    });
  });
}
```

**Step 2: Run test (expect failure)**

Run: `flutter test test/facade_test.dart`
Expected: FAIL — `OitVideoCall` not defined.

**Step 3: Implement**

Create `lib/src/facade.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'config.dart';
import 'models/video_user.dart';

class OitVideoCall {
  OitVideoCall._();

  static OitVideoCallConfig? _config;

  static bool get isInitialized => _config != null;

  static OitVideoCallConfig get configOrThrow {
    final c = _config;
    if (c == null) {
      throw StateError('OitVideoCall.init() has not been called.');
    }
    return c;
  }

  static Future<void> init({
    required String apiKey,
    required VideoUser user,
    required TokenProvider tokenProvider,
  }) async {
    _config = OitVideoCallConfig(
      apiKey: apiKey,
      user: user,
      tokenProvider: tokenProvider,
    );
  }

  static Future<void> reset() async {
    _config = null;
  }

  // callScreen() is added in Task 11.
  static Widget callScreen({
    required String callId,
    bool audioOnly = false,
    String callType = 'default',
    VoidCallback? onCallEnded,
  }) {
    throw UnimplementedError('Wired in Task 11');
  }
}
```

**Step 4: Run test (expect pass)**

Run: `flutter test test/facade_test.dart`
Expected: all 4 tests passing.

**Step 5: Commit**

```bash
git add lib/src/facade.dart test/facade_test.dart
git commit -m "feat: add OitVideoCall facade with init/isInitialized/reset"
```

---

## Phase E — Error view widget

### Task 11: _ErrorView widget + callScreen-before-init wiring

**Files:**
- Create: `lib/src/screen/error_view.dart`
- Modify: `lib/src/facade.dart`
- Create: `test/screen/error_view_test.dart`
- Create: `test/facade_call_screen_test.dart`

**Step 1: Write the failing _ErrorView test**

Create `test/screen/error_view_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/errors.dart';
import 'package:oit_video_call/src/screen/error_view.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: child));

  testWidgets('renders message and Close button by default', (tester) async {
    await tester.pumpWidget(host(const ErrorView(
      code: OitVideoCallErrorCode.callNotFound,
      message: 'No such call',
    )));

    expect(find.text('No such call'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('shows Retry action when provided', (tester) async {
    var retryCount = 0;
    await tester.pumpWidget(host(ErrorView(
      code: OitVideoCallErrorCode.permissionDenied,
      message: 'Mic + camera required',
      onRetry: () => retryCount++,
    )));

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retryCount, 1);
  });

  testWidgets('shows Open Settings action when provided', (tester) async {
    var settingsCount = 0;
    await tester.pumpWidget(host(ErrorView(
      code: OitVideoCallErrorCode.permissionDenied,
      message: 'Permission permanently denied',
      onOpenSettings: () => settingsCount++,
    )));

    expect(find.text('Open Settings'), findsOneWidget);
    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(settingsCount, 1);
  });
}
```

**Step 2: Run test (expect failure)**

Run: `flutter test test/screen/error_view_test.dart`
Expected: FAIL — `error_view.dart` not found.

**Step 3: Implement ErrorView**

Create `lib/src/screen/error_view.dart`:

```dart
import 'package:flutter/material.dart';
import '../errors.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.code,
    required this.message,
    this.onRetry,
    this.onOpenSettings,
  });

  final OitVideoCallErrorCode code;
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              children: [
                if (onRetry != null)
                  FilledButton(onPressed: onRetry, child: const Text('Retry')),
                if (onOpenSettings != null)
                  OutlinedButton(
                    onPressed: onOpenSettings,
                    child: const Text('Open Settings'),
                  ),
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

**Step 4: Run ErrorView test (expect pass)**

Run: `flutter test test/screen/error_view_test.dart`
Expected: 3 tests passing.

**Step 5: Write failing facade-callScreen test**

Create `test/facade_call_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/oit_video_call.dart';

void main() {
  setUp(() async {
    await OitVideoCall.reset();
  });

  testWidgets('callScreen before init shows notInitialized error', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OitVideoCall.callScreen(callId: 'c1'),
    ));
    await tester.pump();

    expect(find.textContaining('not initialized', findRichText: true), findsOneWidget);
  });
}
```

**Step 6: Update lib/oit_video_call.dart with public exports**

Replace contents of `lib/oit_video_call.dart`:

```dart
library oit_video_call;

export 'src/facade.dart' show OitVideoCall;
export 'src/models/video_user.dart' show VideoUser;
export 'src/errors.dart' show OitVideoCallException, OitVideoCallErrorCode;
```

**Step 7: Wire callScreen → ErrorView for the not-initialized case**

In `lib/src/facade.dart`, replace the `callScreen` body:

```dart
  static Widget callScreen({
    required String callId,
    bool audioOnly = false,
    String callType = 'default',
    VoidCallback? onCallEnded,
  }) {
    if (_config == null) {
      return const Scaffold(
        body: ErrorView(
          code: OitVideoCallErrorCode.notInitialized,
          message: 'OitVideoCall is not initialized. Call OitVideoCall.init() first.',
        ),
      );
    }
    // Real screen wired in Task 17.
    return const Scaffold(
      body: Center(child: Text('CallScreen placeholder — wired in Task 17')),
    );
  }
```

Add the matching imports at the top of `lib/src/facade.dart`:

```dart
import 'package:flutter/material.dart';
import 'errors.dart';
import 'screen/error_view.dart';
```

(Remove the `package:flutter/widgets.dart` import since we now use `material.dart`.)

**Step 8: Run all tests**

Run: `flutter test`
Expected: every test passing.

**Step 9: Commit**

```bash
git add lib/oit_video_call.dart lib/src/facade.dart lib/src/screen/error_view.dart test/screen/error_view_test.dart test/facade_call_screen_test.dart
git commit -m "feat: add ErrorView and wire callScreen not-initialized branch"
```

---

## Phase F — Call session abstraction (testability layer)

### Task 12: Define _CallSession interface + Fake for tests

**Files:**
- Create: `lib/src/screen/call_session.dart`
- Create: `test/screen/call_session_test.dart` (just to verify the fake compiles + behaves)

**Step 1: Write the interface + fake**

Create `lib/src/screen/call_session.dart`:

```dart
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// Abstraction over the Stream API surface our screen uses.
/// Real impl wraps stream_video; fake impl is used in tests.
abstract class CallSession {
  Future<void> connect({required String apiKey, required User user, required String token});
  Future<Call> getCall({required String callType, required String callId});
  Future<void> joinCall(Call call);
  Future<void> setCameraEnabled(Call call, bool enabled);
  Future<void> leaveCall(Call call);
  Future<void> dispose();
}

/// Real Stream-backed implementation.
class StreamCallSession implements CallSession {
  StreamVideo? _video;

  @override
  Future<void> connect({required String apiKey, required User user, required String token}) async {
    _video = StreamVideo(apiKey, user: user, userToken: token);
  }

  @override
  Future<Call> getCall({required String callType, required String callId}) async {
    final call = StreamVideo.instance.makeCall(
      callType: StreamCallType.fromString(callType),
      id: callId,
    );
    final result = await call.get();
    if (result.isFailure) {
      throw Exception('call.get() failed: ${result.getError()}');
    }
    return call;
  }

  @override
  Future<void> joinCall(Call call) async {
    final result = await call.join(create: false);
    if (result.isFailure) {
      throw Exception('call.join() failed: ${result.getError()}');
    }
  }

  @override
  Future<void> setCameraEnabled(Call call, bool enabled) async {
    await call.setCameraEnabled(enabled: enabled);
  }

  @override
  Future<void> leaveCall(Call call) async {
    await call.leave();
  }

  @override
  Future<void> dispose() async {
    await StreamVideo.reset();
    _video = null;
  }
}
```

> **Note for engineer:** The exact return-type handling of `call.get()` and `call.join()` may differ across Stream Video Flutter versions (`Result<T>` vs raw throws). If `flutter analyze` complains about `.isFailure` / `.getError()`, replace with the version-correct API — the goal is "throws on failure, returns the call on success." Check `package:stream_video_flutter`'s public API in `flutter pub get` cache.

**Step 2: Run analyze to confirm it compiles against the real Stream API**

Run: `dart analyze lib/src/screen/call_session.dart`
Expected: clean. If errors → fix per the note above.

**Step 3: Commit**

```bash
git add lib/src/screen/call_session.dart
git commit -m "feat: add CallSession abstraction with StreamCallSession impl"
```

---

### Task 13: Add FakeCallSession for tests

**Files:**
- Create: `test/screen/fake_call_session.dart`

**Step 1: Implement the fake**

Create `test/screen/fake_call_session.dart`:

```dart
import 'package:oit_video_call/src/screen/call_session.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// In-memory CallSession for unit tests.
class FakeCallSession implements CallSession {
  // Configurable failure modes — set before mounting the screen.
  Object? connectError;
  Object? getCallError; // throw to simulate failure
  bool getCallNotFound = false; // simulates 404
  Object? joinError;

  // Observable state.
  int connectCount = 0;
  int joinCount = 0;
  int leaveCount = 0;
  int disposeCount = 0;
  final List<bool> cameraEnabledCalls = [];

  Call? _call;

  @override
  Future<void> connect({required String apiKey, required User user, required String token}) async {
    connectCount++;
    if (connectError != null) throw connectError!;
  }

  @override
  Future<Call> getCall({required String callType, required String callId}) async {
    if (getCallNotFound) {
      throw const _CallNotFoundError();
    }
    if (getCallError != null) throw getCallError!;
    // Return a sentinel — _CallScreen doesn't introspect it, only passes it through.
    _call = _FakeCall();
    return _call!;
  }

  @override
  Future<void> joinCall(Call call) async {
    if (joinError != null) throw joinError!;
    joinCount++;
  }

  @override
  Future<void> setCameraEnabled(Call call, bool enabled) async {
    cameraEnabledCalls.add(enabled);
  }

  @override
  Future<void> leaveCall(Call call) async {
    leaveCount++;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

class _CallNotFoundError implements Exception {
  const _CallNotFoundError();
  @override
  String toString() => 'CallNotFound';
}

bool isCallNotFoundError(Object e) => e is _CallNotFoundError;

// Minimal Call sentinel — the screen never inspects this in tests.
class _FakeCall implements Call {
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeCall.${invocation.memberName}');
}
```

> **Note:** `_FakeCall extends Call` only as a type bridge; tests must not exercise any Call method. If the test path reaches a real Call method, it's testing the wrong layer — that's a smoke-test concern, not a unit test.

**Step 2: Verify it compiles**

Run: `dart analyze test/screen/fake_call_session.dart`
Expected: clean.

**Step 3: Commit**

```bash
git add test/screen/fake_call_session.dart
git commit -m "test: add FakeCallSession for screen lifecycle tests"
```

---

### Task 14: Define a permission-handler abstraction + fake

**Files:**
- Create: `lib/src/screen/permission_gate.dart`
- Create: `test/screen/fake_permission_gate.dart`

**Step 1: Define the interface + real impl**

Create `lib/src/screen/permission_gate.dart`:

```dart
import 'package:permission_handler/permission_handler.dart';

class PermissionResult {
  const PermissionResult({required this.granted, required this.permanentlyDenied});
  final bool granted;
  final bool permanentlyDenied;
}

/// Requests OS permissions. Abstracted for tests.
abstract class PermissionGate {
  /// If [includeCamera] is false, only microphone is requested.
  Future<PermissionResult> request({required bool includeCamera});
}

class RealPermissionGate implements PermissionGate {
  @override
  Future<PermissionResult> request({required bool includeCamera}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (includeCamera) Permission.camera,
    ];
    final statuses = await permissions.request();
    final granted = statuses.values.every((s) => s.isGranted);
    final permanentlyDenied =
        statuses.values.any((s) => s.isPermanentlyDenied);
    return PermissionResult(
      granted: granted,
      permanentlyDenied: permanentlyDenied,
    );
  }
}
```

**Step 2: Create the fake**

Create `test/screen/fake_permission_gate.dart`:

```dart
import 'package:oit_video_call/src/screen/permission_gate.dart';

class FakePermissionGate implements PermissionGate {
  PermissionResult result = const PermissionResult(granted: true, permanentlyDenied: false);
  bool? lastIncludeCamera;
  int requestCount = 0;

  @override
  Future<PermissionResult> request({required bool includeCamera}) async {
    requestCount++;
    lastIncludeCamera = includeCamera;
    return result;
  }
}
```

**Step 3: Commit**

```bash
git add lib/src/screen/permission_gate.dart test/screen/fake_permission_gate.dart
git commit -m "feat: add PermissionGate abstraction with RealPermissionGate"
```

---

## Phase G — _CallScreen lifecycle (TDD)

### Task 15: Skeleton _CallScreen with constructor-injected deps

**Files:**
- Create: `lib/src/screen/call_screen.dart`

**Step 1: Implement the skeleton (just enough to compile)**

Create `lib/src/screen/call_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';
import '../config.dart';
import '../errors.dart';
import 'call_session.dart';
import 'error_view.dart';
import 'permission_gate.dart';

@visibleForTesting
class CallScreenDeps {
  const CallScreenDeps({this.session, this.permissionGate, this.openSettings});
  final CallSession? session;
  final PermissionGate? permissionGate;
  final Future<bool> Function()? openSettings;
}

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.config,
    required this.callId,
    required this.callType,
    required this.audioOnly,
    this.onCallEnded,
    @visibleForTesting this.deps,
  });

  final OitVideoCallConfig config;
  final String callId;
  final String callType;
  final bool audioOnly;
  final VoidCallback? onCallEnded;

  @visibleForTesting
  final CallScreenDeps? deps;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

sealed class _Phase {}
class _Loading extends _Phase {}
class _Errored extends _Phase {
  _Errored(this.code, this.message, {this.canRetry = true, this.canOpenSettings = false});
  final OitVideoCallErrorCode code;
  final String message;
  final bool canRetry;
  final bool canOpenSettings;
}
class _Ready extends _Phase {
  _Ready(this.call);
  final Call call;
}

class _CallScreenState extends State<CallScreen> {
  late final CallSession _session;
  late final PermissionGate _gate;
  late final Future<bool> Function() _openSettings;
  Call? _call;
  _Phase _phase = _Loading();

  @override
  void initState() {
    super.initState();
    _session = widget.deps?.session ?? StreamCallSession();
    _gate = widget.deps?.permissionGate ?? RealPermissionGate();
    _openSettings = widget.deps?.openSettings ?? () => Future.value(false);
    _start();
  }

  Future<void> _start() async {
    // Implemented in Task 16.
  }

  @override
  void dispose() {
    if (_call != null) {
      _session.leaveCall(_call!);
    }
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: switch (_phase) {
      _Loading() => const Center(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Joining call…'),
          ],
        )),
      _Errored(code: final c, message: final m, canRetry: final r, canOpenSettings: final s) => ErrorView(
          code: c,
          message: m,
          onRetry: r ? _retry : null,
          onOpenSettings: s ? () => _openSettings() : null,
        ),
      _Ready(call: final call) => StreamCallContainer(call: call),
    });
  }

  void _retry() {
    setState(() => _phase = _Loading());
    _start();
  }
}
```

**Step 2: Run analyzer**

Run: `dart analyze lib/src/screen/call_screen.dart`
Expected: clean (the `_start()` is empty for now).

**Step 3: Commit**

```bash
git add lib/src/screen/call_screen.dart
git commit -m "feat: add CallScreen skeleton with phase state machine"
```

---

### Task 16: Implement the 5-phase lifecycle in _start()

**Files:**
- Modify: `lib/src/screen/call_screen.dart`

**Step 1: Replace _start() with the full state machine**

In `lib/src/screen/call_screen.dart`, replace the `_start()` method:

```dart
  Future<void> _start() async {
    // Phase 1: permissions
    final perm = await _gate.request(includeCamera: !widget.audioOnly);
    if (!mounted) return;
    if (!perm.granted) {
      setState(() => _phase = _Errored(
        OitVideoCallErrorCode.permissionDenied,
        perm.permanentlyDenied
          ? 'Permission permanently denied. Open settings to grant.'
          : 'Camera and microphone are required.',
        canRetry: !perm.permanentlyDenied,
        canOpenSettings: perm.permanentlyDenied,
      ));
      return;
    }

    // Phase 2: token
    final String token;
    try {
      token = await widget.config.tokenProvider();
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Errored(
        OitVideoCallErrorCode.tokenFetchFailed,
        'Could not fetch call token.',
      ));
      return;
    }

    // Phase 3: connect
    try {
      final user = User.regular(
        userId: widget.config.user.id,
        name: widget.config.user.name,
        image: widget.config.user.image,
      );
      await _session.connect(
        apiKey: widget.config.apiKey,
        user: user,
        token: token,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Errored(
        OitVideoCallErrorCode.joinFailed,
        'Could not connect to call service.',
      ));
      return;
    }

    // Phase 4: get call (no create)
    final Call call;
    try {
      call = await _session.getCall(callType: widget.callType, callId: widget.callId);
    } catch (e) {
      if (!mounted) return;
      final notFound = e.toString().toLowerCase().contains('not') &&
          e.toString().toLowerCase().contains('found');
      setState(() => _phase = _Errored(
        notFound ? OitVideoCallErrorCode.callNotFound : OitVideoCallErrorCode.joinFailed,
        notFound ? 'Call not available.' : 'Could not load call.',
      ));
      return;
    }

    // Phase 5: join
    try {
      await _session.joinCall(call);
      if (widget.audioOnly) {
        await _session.setCameraEnabled(call, false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Errored(
        OitVideoCallErrorCode.joinFailed,
        'Could not join call.',
      ));
      return;
    }

    if (!mounted) return;
    _call = call;
    setState(() => _phase = _Ready(call));
  }
```

> **Note on the `notFound` heuristic:** Stream's actual error type for "call doesn't exist" varies across versions. The string-contains check is a pragmatic fallback. If the engineer can identify a stable error class on the version we pin, replace the heuristic with `e is StreamCallNotFoundError` (or similar). Otherwise, the heuristic is acceptable for v1.

**Step 2: Commit**

```bash
git add lib/src/screen/call_screen.dart
git commit -m "feat: implement CallScreen 5-phase lifecycle"
```

---

### Task 17: Test phase 1 — permissions denied (temporary)

**Files:**
- Create: `test/screen/call_screen_test.dart`

**Step 1: Write the failing test**

Create `test/screen/call_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/models/video_user.dart';
import 'package:oit_video_call/src/screen/call_screen.dart';
import 'package:oit_video_call/src/screen/permission_gate.dart';

import 'fake_call_session.dart';
import 'fake_permission_gate.dart';

OitVideoCallConfig _config({Future<String> Function()? tokenProvider}) =>
    OitVideoCallConfig(
      apiKey: 'key',
      user: const VideoUser(id: 'u1', name: 'Foo'),
      tokenProvider: tokenProvider ?? (() async => 'jwt'),
    );

Widget _host({
  required OitVideoCallConfig config,
  required FakeCallSession session,
  required FakePermissionGate gate,
  bool audioOnly = false,
  Future<bool> Function()? openSettings,
}) {
  return MaterialApp(
    home: CallScreen(
      config: config,
      callId: 'c1',
      callType: 'default',
      audioOnly: audioOnly,
      deps: CallScreenDeps(
        session: session,
        permissionGate: gate,
        openSettings: openSettings,
      ),
    ),
  );
}

void main() {
  testWidgets('phase 1: permissions temporarily denied → Retry shown', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(granted: false, permanentlyDenied: false);

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('required'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open Settings'), findsNothing);
  });
}
```

**Step 2: Run test (expect pass — code is in place)**

Run: `flutter test test/screen/call_screen_test.dart`
Expected: 1 test passing.

**Step 3: Commit**

```bash
git add test/screen/call_screen_test.dart
git commit -m "test: phase 1 — permissions temporarily denied"
```

---

### Task 18: Test phase 1 — permanently denied

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append the test**

Inside `void main()`, add:

```dart
  testWidgets('phase 1: permanently denied → Open Settings shown', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate()
      ..result = const PermissionResult(granted: false, permanentlyDenied: true);

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('permanently'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
```

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: phase 1 — permanently denied opens settings"
```

---

### Task 19: Test phase 1 — audioOnly skips camera

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append the test**

```dart
  testWidgets('audioOnly skips camera permission', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      audioOnly: true,
    ));
    await tester.pumpAndSettle();

    expect(gate.lastIncludeCamera, false);
    // Audio-only also means setCameraEnabled(false) post-join
    expect(session.cameraEnabledCalls, contains(false));
  });

  testWidgets('video call requests camera permission', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(
      config: _config(),
      session: session,
      gate: gate,
      audioOnly: false,
    ));
    await tester.pumpAndSettle();

    expect(gate.lastIncludeCamera, true);
    expect(session.cameraEnabledCalls, isEmpty);
  });
```

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: audioOnly toggles camera permission and post-join camera state"
```

---

### Task 20: Test phase 2 — token fetch failure

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append**

```dart
  testWidgets('phase 2: tokenProvider throws → tokenFetchFailed error', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(
      config: _config(tokenProvider: () => Future.error(Exception('500'))),
      session: session,
      gate: gate,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('token'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
```

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: phase 2 — token fetch failure"
```

---

### Task 21: Test phase 3 — connect failure

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append**

```dart
  testWidgets('phase 3: session.connect throws → joinFailed', (tester) async {
    final session = FakeCallSession()..connectError = Exception('boom');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('connect'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
```

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: phase 3 — connect failure"
```

---

### Task 22: Test phase 4 — call not found vs general error

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append**

```dart
  testWidgets('phase 4: getCall not found → callNotFound', (tester) async {
    final session = FakeCallSession()..getCallNotFound = true;
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('not available'), findsOneWidget);
  });

  testWidgets('phase 4: getCall throws other error → joinFailed', (tester) async {
    final session = FakeCallSession()..getCallError = Exception('boom');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('load call'), findsOneWidget);
  });
```

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: phase 4 — call not found and general failure"
```

---

### Task 23: Test phase 5 — join failure

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append**

```dart
  testWidgets('phase 5: joinCall throws → joinFailed', (tester) async {
    final session = FakeCallSession()..joinError = Exception('rtc fail');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(find.textContaining('join'), findsOneWidget);
  });
```

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: phase 5 — join failure"
```

---

### Task 24: Test full success path counts

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append**

```dart
  testWidgets('happy path: connect + join called once each', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    expect(session.connectCount, 1);
    expect(session.joinCount, 1);
  });
```

> **Note:** This test will reach the `_Ready` state which renders `StreamCallContainer(call: _FakeCall())`. The widget will likely throw at build time because `_FakeCall.noSuchMethod` isn't a real Call. If `flutter test` complains, wrap the assertion check before `pumpAndSettle()` finishes — use `tester.pump()` once and check the counters; the build crash is acceptable in tests because we only care about the `_session` interaction, not the rendering.

**Alternative implementation for Step 1 if `pumpAndSettle()` crashes**:

```dart
  testWidgets('happy path: connect + join called once each', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    // Pump enough times for async phases to complete, but don't settle into the
    // _Ready render which would try to build StreamCallContainer with FakeCall.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(session.connectCount, 1);
    expect(session.joinCount, 1);
  });
```

Use whichever variant runs cleanly.

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: happy path runs connect + join exactly once"
```

---

### Task 25: Test dispose lifecycle

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append**

```dart
  testWidgets('dispose calls leaveCall + dispose on session', (tester) async {
    final session = FakeCallSession();
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // Now unmount the screen by replacing the widget tree.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(session.leaveCount, 1);
    expect(session.disposeCount, 1);
  });
```

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: dispose calls leaveCall and session.dispose"
```

---

### Task 26: Test Retry re-runs the lifecycle

**Files:**
- Modify: `test/screen/call_screen_test.dart`

**Step 1: Append**

```dart
  testWidgets('Retry re-runs phases', (tester) async {
    final session = FakeCallSession()..connectError = Exception('boom');
    final gate = FakePermissionGate();

    await tester.pumpWidget(_host(config: _config(), session: session, gate: gate));
    await tester.pumpAndSettle();

    // First attempt failed at phase 3.
    expect(find.text('Retry'), findsOneWidget);
    expect(session.connectCount, 1);

    // Clear the error and retry.
    session.connectError = null;

    await tester.tap(find.text('Retry'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(session.connectCount, 2);
    expect(session.joinCount, 1);
  });
```

**Step 2: Run + commit**

```bash
flutter test test/screen/call_screen_test.dart
git add test/screen/call_screen_test.dart
git commit -m "test: Retry re-runs phases"
```

---

## Phase H — Wire facade.callScreen → _CallScreen

### Task 27: Replace facade placeholder with real CallScreen

**Files:**
- Modify: `lib/src/facade.dart`

**Step 1: Update callScreen to construct CallScreen**

In `lib/src/facade.dart`, replace the placeholder return with:

```dart
    return CallScreen(
      config: _config!,
      callId: callId,
      callType: callType,
      audioOnly: audioOnly,
      onCallEnded: onCallEnded,
    );
```

Add the import:

```dart
import 'screen/call_screen.dart';
```

(Remove the `Scaffold/Center/Text` placeholder.)

**Step 2: Run all tests**

Run: `flutter test`
Expected: every test passing.

**Step 3: Commit**

```bash
git add lib/src/facade.dart
git commit -m "feat: wire facade.callScreen to real CallScreen"
```

---

## Phase I — Example app

### Task 28: Generate example app

**Files:**
- Create: `example/` (entire Flutter app via `flutter create`)

**Step 1: Generate**

Run:
```bash
cd /Users/prabhatpatel/development/Github/video_call
flutter create --platforms=android,ios --org in.dharmayana --project-name oit_video_call_example example
```

**Step 2: Add path dep on the plugin**

Edit `example/pubspec.yaml`. Inside `dependencies:`:

```yaml
  oit_video_call:
    path: ../
  flutter_dotenv: ^5.2.1
```

Add to `flutter:` section:

```yaml
  assets:
    - .env
```

**Step 3: Run `pub get`**

```bash
cd example && flutter pub get && cd ..
```

**Step 4: Commit**

```bash
git add example/
git commit -m "chore: scaffold example app with path dep on plugin"
```

---

### Task 29: Example app UI + wiring

**Files:**
- Modify: `example/lib/main.dart`
- Create: `example/.env.example`

**Step 1: Replace example/lib/main.dart**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:oit_video_call/oit_video_call.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});
  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: const HomePage());
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _userIdCtrl = TextEditingController(text: 'demo-user');
  final _userNameCtrl = TextEditingController(text: 'Demo User');
  final _callIdCtrl = TextEditingController();
  bool _audioOnly = false;
  bool _initialized = false;

  Future<void> _initAndJoin() async {
    final apiKey = dotenv.env['STREAM_API_KEY'];
    final demoToken = dotenv.env['STREAM_DEMO_TOKEN'];
    if (apiKey == null || demoToken == null) {
      _toast('Set STREAM_API_KEY and STREAM_DEMO_TOKEN in .env');
      return;
    }

    if (!_initialized) {
      await OitVideoCall.init(
        apiKey: apiKey,
        user: VideoUser(id: _userIdCtrl.text, name: _userNameCtrl.text),
        tokenProvider: () async => demoToken,
      );
      _initialized = true;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OitVideoCall.callScreen(
          callId: _callIdCtrl.text,
          audioOnly: _audioOnly,
        ),
      ),
    );
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('oit_video_call demo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(controller: _userIdCtrl, decoration: const InputDecoration(labelText: 'User ID')),
            TextField(controller: _userNameCtrl, decoration: const InputDecoration(labelText: 'User Name')),
            TextField(controller: _callIdCtrl, decoration: const InputDecoration(labelText: 'Call ID')),
            CheckboxListTile(
              title: const Text('Audio only'),
              value: _audioOnly,
              onChanged: (v) => setState(() => _audioOnly = v ?? false),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _initAndJoin, child: const Text('Join call')),
          ],
        ),
      ),
    );
  }
}
```

**Step 2: Add .env.example**

Create `example/.env.example`:

```
STREAM_API_KEY=replace_with_stream_dashboard_key
STREAM_DEMO_TOKEN=replace_with_a_dev_jwt_for_user_demo-user
```

**Step 3: Add iOS Info.plist strings to example app**

Edit `example/ios/Runner/Info.plist` — inside the top-level `<dict>`, add:

```xml
<key>NSCameraUsageDescription</key>
<string>Used for video consultations.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Used for audio during consultations.</string>
```

**Step 4: Verify build**

Run:
```bash
cd example
flutter build apk --debug
cd ..
```

Expected: build succeeds. (We're not running it — just verifying it compiles.)

**Step 5: Commit**

```bash
git add example/lib/main.dart example/.env.example example/ios/Runner/Info.plist example/pubspec.yaml example/pubspec.lock
git commit -m "feat(example): UI for joining a Stream call from the demo app"
```

---

## Phase J — Documentation + release

### Task 30: README

**Files:**
- Modify: `README.md`

**Step 1: Replace README.md**

```markdown
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
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with integration guide"
```

---

### Task 31: Final verification + tag

**Files:**
- (None)

**Step 1: Run all tests**

Run: `flutter test`
Expected: every test passing, no warnings.

**Step 2: Run analyzer**

Run: `dart analyze`
Expected: no issues.

**Step 3: Confirm clean tree**

Run: `git status`
Expected: nothing to commit.

**Step 4: Tag v1.0.0**

```bash
git tag -a v1.0.0 -m "v1.0.0 — initial plugin release"
git tag --list
```

> **Note:** Do NOT push the tag yet. After the user merges `release/1.0.0` → `master`, tagging happens on master with `git push -u origin master && git push origin v1.0.0`.

**Step 5: Final summary to user**

Report:
- Tasks completed: 31
- Tests: N passing
- Pending push: yes (release/1.0.0 + v1.0.0 tag)
- Smoke test: still pending — example app needs a real Stream API key + JWT.

---

## What's NOT in this plan (intentionally)

- **Host-app integration into `dharmayana_app` and `dharmayana_mitra_app`.** Once the plugin is tagged, that's a separate, much smaller plan: add the git dep, add the Info.plist strings, place `OitVideoCall.init` in the right startup hook, and replace the consultation entry point with `Navigator.push(... callScreen ...)`. That work depends on the host apps' token-fetching code, which the user will write later.
- **Token endpoint design or backend Stream provisioning.** Out of scope.
- **Push notifications for incoming calls.** v2.
- **CallKit / ConnectionService.** v2.
- **Localization of plugin error strings.** v2.

---

## How to know each task succeeded

After every task, you should be able to:
1. Run `flutter test` and see all current tests passing.
2. Run `dart analyze` and see no errors.
3. See exactly one new commit in `git log --oneline`.

If any of those fail, **stop and diagnose** — do not move to the next task.
