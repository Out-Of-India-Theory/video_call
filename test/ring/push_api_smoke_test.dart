import 'package:flutter_test/flutter_test.dart';
import 'package:stream_video_push_notification/stream_video_push_notification.dart';

void main() {
  test('push notification API symbols are present', () {
    // create() returns a PNManagerProvider function — referencing it proves
    // the factory + provider constructors exist on the resolved version.
    final provider = StreamVideoPushNotificationManager.create(
      iosPushProvider: const StreamVideoPushProvider.apn(name: 'x'),
      androidPushProvider: const StreamVideoPushProvider.firebase(name: 'y'),
      registerApnDeviceToken: true,
    );
    expect(provider, isNotNull);
  });
}
