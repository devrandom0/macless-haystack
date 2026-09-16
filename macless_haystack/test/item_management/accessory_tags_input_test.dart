import 'package:macless_haystack/item_management/accessory_tags_input.dart';
import 'package:test/test.dart';

void main() {
  group('tagsAfterAdding', () {
    test('adds a new tag', () {
      expect(tagsAfterAdding(['Keys'], 'Car'), ['Keys', 'Car']);
    });

    test('trims surrounding whitespace before adding', () {
      expect(tagsAfterAdding([], '  Car  '), ['Car']);
    });

    test('does not add an empty or whitespace-only tag', () {
      expect(tagsAfterAdding(['Keys'], ''), ['Keys']);
      expect(tagsAfterAdding(['Keys'], '   '), ['Keys']);
    });

    test('does not add a tag that already exists (exact match)', () {
      expect(tagsAfterAdding(['Keys'], 'Keys'), ['Keys']);
    });

    test('is case-sensitive - "car" and "Car" are different tags', () {
      expect(tagsAfterAdding(['Car'], 'car'), ['Car', 'car']);
    });
  });

  group('tagsAfterRemoving', () {
    test('removes the given tag', () {
      expect(tagsAfterRemoving(['Keys', 'Car'], 'Keys'), ['Car']);
    });

    test('is a no-op if the tag is not present', () {
      expect(tagsAfterRemoving(['Keys'], 'Car'), ['Keys']);
    });
  });
}
