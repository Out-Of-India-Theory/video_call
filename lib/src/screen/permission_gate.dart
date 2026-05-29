import 'package:permission_handler/permission_handler.dart';

/// Outcome of an OS permission request.
///
/// Microphone is mandatory — without it the user can't participate in the
/// call. Camera is best-effort: when not granted, the screen downgrades
/// to audio-only rather than blocking the join, so the user can still
/// hear/talk and grant camera mid-call via the in-call toggle.
class PermissionResult {
  const PermissionResult({
    required this.microphoneGranted,
    required this.cameraGranted,
  });

  /// True when microphone is granted.
  final bool microphoneGranted;

  /// True when camera was requested and granted. False either when camera
  /// was not requested (audio-only join) or when it was requested and
  /// declined — the caller joins audio-only in both cases.
  final bool cameraGranted;
}

/// Requests OS permissions. Abstracted so unit tests can swap in a fake
/// (`FakePermissionGate`) instead of triggering the real OS prompt.
abstract class PermissionGate {
  /// Requests microphone (and, when [includeCamera] is true, camera).
  Future<PermissionResult> request({required bool includeCamera});
}

/// Default implementation backed by `permission_handler` (12.x).
class RealPermissionGate implements PermissionGate {
  @override
  Future<PermissionResult> request({required bool includeCamera}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (includeCamera) Permission.camera,
    ];

    // Pre-check status and only `.request()` the permissions that aren't
    // already granted. On web, `Permission.x.status` queries the W3C
    // Permissions API (`navigator.permissions.query`) which returns
    // `granted` for site settings like Chrome's "Always allow" — without
    // triggering `getUserMedia`. This sidesteps a fragility in
    // `permission_handler_html`'s `requestPermissions`: it loops
    // permission-by-permission, calling `getUserMedia({audio:true})` then
    // `getUserMedia({video:true})` back-to-back. On mobile Chrome (seen
    // on Oppo) the second call can throw `DOMException` (e.g.
    // `NotReadableError` while the just-stopped mic track is still
    // releasing the device) — `permission_handler_html` then reports the
    // already-granted camera as `permanentlyDenied`, even though the
    // browser never blocked us. Skipping the call when the Permissions
    // API already says `granted` is the smallest correct fix and is a
    // no-op on iOS/Android, where `status` reflects the same allow state
    // that `request()` would short-circuit on.
    final statuses = <Permission, PermissionStatus>{};
    final toRequest = <Permission>[];
    for (final p in permissions) {
      // `permission_handler_html.query()` throws `TypeError` on browsers
      // that don't accept `camera`/`microphone` as Permissions API names
      // (e.g. Safari < 16). Treat that as "unknown — go ask" rather than
      // letting it bubble; falling through to `.request()` preserves the
      // pre-fix behavior for those browsers.
      PermissionStatus current;
      try {
        current = await p.status;
      } catch (_) {
        current = PermissionStatus.denied;
      }
      if (current.isGranted) {
        statuses[p] = current;
      } else {
        toRequest.add(p);
      }
    }
    if (toRequest.isNotEmpty) {
      statuses.addAll(await toRequest.request());
    }

    final micStatus = statuses[Permission.microphone];
    final camStatus = includeCamera ? statuses[Permission.camera] : null;
    return PermissionResult(
      microphoneGranted: micStatus?.isGranted ?? false,
      cameraGranted: camStatus?.isGranted ?? false,
    );
  }
}
