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
