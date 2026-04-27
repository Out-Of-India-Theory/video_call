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
