import 'package:macless_haystack/util/place_format.dart';
import 'package:test/test.dart';

void main() {
  group('formatPlacePair', () {
    test('joins two non-null parts with a comma', () {
      expect(formatPlacePair('Mashhad', 'Razavi Khorasan'), 'Mashhad, Razavi Khorasan');
    });

    test('returns just the first part when the second is null', () {
      expect(formatPlacePair('Mashhad', null), 'Mashhad');
    });

    test('returns just the second part when the first is null', () {
      expect(formatPlacePair(null, 'Razavi Khorasan'), 'Razavi Khorasan');
    });

    test('returns null when both parts are null', () {
      expect(formatPlacePair(null, null), null);
    });

    test('treats an empty string the same as null', () {
      expect(formatPlacePair('Mashhad', ''), 'Mashhad');
      expect(formatPlacePair('', ''), null);
    });
  });
}
