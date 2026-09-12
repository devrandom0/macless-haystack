import 'package:macless_haystack/accessory/accessory_list.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:test/test.dart';

Accessory _accessory(String id, {bool isActive = true}) {
  return Accessory(
    id: id,
    name: id,
    hashedPublicKey: 'hash-$id',
    datePublished: DateTime.now(),
    isActive: isActive,
    lastLocation: null,
    hashesWithTS: {},
    locationHistory: [],
    lastBatteryStatus: null,
    additionalKeys: [],
  );
}

void main() {
  final a1 = _accessory('a1');
  final a2 = _accessory('a2');
  final i1 = _accessory('i1', isActive: false);
  final i2 = _accessory('i2', isActive: false);

  group('activeAccessories', () {
    test('keeps only active accessories, preserving order', () {
      expect(activeAccessories([a1, i1, a2, i2]), [a1, a2]);
    });

    test('returns an empty list when none are active', () {
      expect(activeAccessories([i1, i2]), isEmpty);
    });
  });

  group('inactiveAccessories', () {
    test('keeps only inactive accessories, preserving order', () {
      expect(inactiveAccessories([a1, i1, a2, i2]), [i1, i2]);
    });

    test('returns an empty list when none are inactive', () {
      expect(inactiveAccessories([a1, a2]), isEmpty);
    });
  });

  group('groupHeaderLabel', () {
    test('appends the count in parentheses', () {
      expect(groupHeaderLabel('Active', 3), 'Active (3)');
    });

    test('shows zero rather than omitting the group', () {
      expect(groupHeaderLabel('Inactive', 0), 'Inactive (0)');
    });
  });

  group('mergedOrderAfterGroupReorder', () {
    test('splices a reordered active group back in front of the inactives',
        () {
      var result = mergedOrderAfterGroupReorder(
        allAccessories: [a1, i1, a2, i2],
        reorderedGroup: [a2, a1],
        reorderedGroupIsActive: true,
      );
      expect(result, [a2, a1, i1, i2]);
    });

    test(
        'splices a reordered inactive group back after the actives, '
        'leaving their relative order untouched', () {
      var result = mergedOrderAfterGroupReorder(
        allAccessories: [a1, i1, a2, i2],
        reorderedGroup: [i2, i1],
        reorderedGroupIsActive: false,
      );
      expect(result, [a1, a2, i2, i1]);
    });
  });
}
