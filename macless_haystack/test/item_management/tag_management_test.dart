import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/item_management/tag_management.dart';
import 'package:test/test.dart';

void main() {
  Accessory withTags(String id, List<String> tags) => Accessory(
      id: id,
      name: 'Test $id',
      hashedPublicKey: '',
      datePublished: null,
      hashesWithTS: {},
      locationHistory: [],
      lastBatteryStatus: null,
      additionalKeys: [],
      tags: tags);

  group('accessoriesAfterTagRename', () {
    test('replaces the old tag with the new one on every matching accessory', () {
      var a = withTags('a', ['Keys', 'Car']);
      var b = withTags('b', ['Car']);
      var c = withTags('c', ['Bag']);

      var result = accessoriesAfterTagRename([a, b, c], 'Car', 'Vehicle');

      expect(result.firstWhere((acc) => acc.id == 'a').tags, ['Keys', 'Vehicle']);
      expect(result.firstWhere((acc) => acc.id == 'b').tags, ['Vehicle']);
      expect(result.any((acc) => acc.id == 'c'), isFalse);
    });

    test('renaming to a tag the accessory already has collapses to one entry, not a duplicate', () {
      var a = withTags('a', ['Keys', 'Car']);

      var result = accessoriesAfterTagRename([a], 'Car', 'Keys');

      expect(result.single.tags, ['Keys']);
    });

    test('returns only the accessories that actually changed', () {
      var a = withTags('a', ['Keys']);
      var b = withTags('b', ['Car']);

      var result = accessoriesAfterTagRename([a, b], 'Car', 'Vehicle');

      expect(result, hasLength(1));
      expect(result.single.id, 'b');
    });
  });

  group('accessoriesAfterTagDelete', () {
    test('removes the tag from every matching accessory', () {
      var a = withTags('a', ['Keys', 'Car']);
      var b = withTags('b', ['Bag']);

      var result = accessoriesAfterTagDelete([a, b], 'Car');

      expect(result, hasLength(1));
      expect(result.single.id, 'a');
      expect(result.single.tags, ['Keys']);
    });

    test('returns an empty list when no accessory has the tag', () {
      var a = withTags('a', ['Keys']);

      expect(accessoriesAfterTagDelete([a], 'Car'), isEmpty);
    });
  });
}
