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

/// Mirrors the shape of `stream_video`'s `VideoError` (a `message` field). We
/// don't import the real type — the matcher reads `.message` dynamically, so a
/// structural stand-in exercises the same path.
class _ErrorWithMessage {
  const _ErrorWithMessage(this.message);

  final String message;
}

void main() {
  group('isCallAlreadyInProgressError', () {
    // `Call.join()` rejects a concurrent join of an already-in-flight cid with
    // this exact message (stream_video call.dart). It means another path (the
    // ring accept-observer's own join) is already bringing this call up — so
    // [joinCall] must treat it as success, not surface a spurious error that
    // strands the user on the "Joining…" screen. This is the guard against the
    // "same user joined 2–4× / two participants from one phone" bug.
    test('returns true for the SDK "same cid is in progress" message', () {
      const error = _ErrorWithMessage(
        'a call with the same cid is in progress',
      );
      expect(isCallAlreadyInProgressError(error), isTrue);
    });

    test('is case-insensitive', () {
      const error = _ErrorWithMessage(
        'A Call With The Same CID Is In Progress',
      );
      expect(isCallAlreadyInProgressError(error), isTrue);
    });

    test('returns false for an unrelated join failure', () {
      const error = _ErrorWithMessage('SFU connection failed');
      expect(isCallAlreadyInProgressError(error), isFalse);
    });

    test('returns false when the error has no message field', () {
      expect(isCallAlreadyInProgressError(const _ErrorWithoutCause()), isFalse);
    });

    test('returns false for a bare Exception', () {
      expect(isCallAlreadyInProgressError(Exception('boom')), isFalse);
    });
  });

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
