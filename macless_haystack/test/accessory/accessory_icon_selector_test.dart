import 'package:macless_haystack/accessory/accessory_icon_selector.dart';
import 'package:test/test.dart';

void main() {
  group('describeAccessoryIconName', () {
    test('strips the .fill suffix', () {
      expect(describeAccessoryIconName('key.fill'), 'Key');
    });

    test('turns internal dots into spaces', () {
      expect(describeAccessoryIconName('figure.walk'), 'Figure walk');
    });

    test('handles multiple dots', () {
      expect(describeAccessoryIconName('latch.2.case.fill'), 'Latch 2 case');
    });

    test('leaves a single word with no separators as one word', () {
      expect(describeAccessoryIconName('mappin'), 'Mappin');
      expect(describeAccessoryIconName('creditcard.fill'), 'Creditcard');
    });

    test('splits an internal camelCase boundary', () {
      expect(describeAccessoryIconName('someCamelCase'), 'Some camel case');
    });

    test('is never left blank for a non-empty input', () {
      expect(describeAccessoryIconName('a'), 'A');
    });
  });
}
