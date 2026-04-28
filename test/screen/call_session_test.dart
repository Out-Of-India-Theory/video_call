import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/screen/call_session.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// Synthesized error mirroring the documented shape of
/// `stream_video`'s private `VideoErrorWithCause` (a `cause` field that
/// holds the underlying transport exception). We do not import the real
/// type because it is not exported by `stream_video`.
class _ErrorWithCause {
  _ErrorWithCause({required this.cause});

  final Object cause;
}

class _ErrorWithoutCause {
  const _ErrorWithoutCause();
}

void main() {
  group('isHttpNotFoundError', () {
    test('returns true for cause = ApiException(404, ...)', () {
      final error = _ErrorWithCause(cause: ApiException(404, 'not found'));
      expect(isHttpNotFoundError(error), isTrue);
    });

    test('returns false for cause = ApiException with non-404 code', () {
      final error = _ErrorWithCause(cause: ApiException(500, 'server'));
      expect(isHttpNotFoundError(error), isFalse);
    });

    test('returns false when cause is not an ApiException', () {
      final error = _ErrorWithCause(cause: 'plain string');
      expect(isHttpNotFoundError(error), isFalse);
    });

    test('returns false when error has no cause field', () {
      expect(isHttpNotFoundError(const _ErrorWithoutCause()), isFalse);
    });

    test('returns false for a bare Exception', () {
      expect(isHttpNotFoundError(Exception('boom')), isFalse);
    });

    test('returns false for null-like inputs handled defensively', () {
      // Cannot pass null to a non-nullable parameter, but a typeless
      // object with a cause-typed-as-null behaves the same as no cause.
      final error = _ErrorWithCause(cause: Object());
      expect(isHttpNotFoundError(error), isFalse);
    });
  });
}
