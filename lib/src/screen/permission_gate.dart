import 'package:permission_handler/permission_handler.dart';

/// Outcome of an OS permission request.
class PermissionResult {
  const PermissionResult({
    required this.granted,
    required this.permanentlyDenied,
  });

  /// True only when every requested permission was granted.
  final bool granted;

  /// True when at least one requested permission has been permanently denied
  /// — the screen should prompt the user to open app settings.
  final bool permanentlyDenied;
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
    final statuses = await permissions.request();
    final granted = statuses.values.every((s) => s.isGranted);
    final permanentlyDenied = statuses.values.any(
      (s) => s.isPermanentlyDenied,
    );
    return PermissionResult(
      granted: granted,
      permanentlyDenied: permanentlyDenied,
    );
  }
}
