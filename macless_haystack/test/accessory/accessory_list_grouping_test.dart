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

    test('does not special-case a zero count', () {
      expect(groupHeaderLabel('Inactive', 0), 'Inactive (0)');
    });
  });

  group('formatDistance', () {
    test('shows whole meters under 1 km', () {
      expect(formatDistance(0.45), '450 m');
    });

    test('rounds to the nearest meter', () {
      expect(formatDistance(0.4567), '457 m');
    });

    test('shows one decimal place at 1 km and above', () {
      expect(formatDistance(1), '1.0 km');
      expect(formatDistance(3.4567890123456789), '3.5 km');
    });
  });

  group('matchesTagFilter', () {
    Accessory withTags(List<String> tags) => Accessory(
        id: '1',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: [],
        tags: tags);

    test('an empty filter matches every accessory', () {
      expect(matchesTagFilter(withTags([]), {}), isTrue);
      expect(matchesTagFilter(withTags(['Keys']), {}), isTrue);
    });

    test('matches an accessory having the one filtered tag', () {
      expect(matchesTagFilter(withTags(['Keys', 'Car']), {'Keys'}), isTrue);
    });

    test('does not match an accessory without any filtered tag', () {
      expect(matchesTagFilter(withTags(['Car']), {'Keys'}), isFalse);
    });

    test('matches an accessory having any one of multiple filtered tags', () {
      expect(
          matchesTagFilter(withTags(['Car']), {'Keys', 'Car'}), isTrue);
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

  group('mergeReorderedVisibleIntoFullGroup', () {
    Accessory buildAccessory(String id) => Accessory(
        id: id,
        name: id,
        hashedPublicKey: 'hash-$id',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: []);

    test('with no hidden items, reflects the new order exactly', () {
      var a = buildAccessory('a');
      var b = buildAccessory('b');
      var c = buildAccessory('c');

      var result = mergeReorderedVisibleIntoFullGroup(
        fullGroup: [a, b, c],
        reorderedVisible: [c, a, b],
      );

      expect(result.map((x) => x.id), ['c', 'a', 'b']);
    });

    test('keeps a hidden item in its original relative position', () {
      var a = buildAccessory('a');
      var hidden = buildAccessory('hidden');
      var b = buildAccessory('b');
      var c = buildAccessory('c');

      // "hidden" sits between a and b in the full group and is filtered
      // out, so the user only ever sees/drags [a, b, c].
      var result = mergeReorderedVisibleIntoFullGroup(
        fullGroup: [a, hidden, b, c],
        reorderedVisible: [c, a, b], // user dragged c to the front
      );

      // "hidden" must still occupy its original absolute slot (index 1)
      // regardless of how the visible items around it get reordered.
      expect(result.map((x) => x.id), ['c', 'hidden', 'a', 'b']);
    });

    test('an empty reorderedVisible leaves fullGroup unchanged', () {
      var a = buildAccessory('a');
      var b = buildAccessory('b');

      var result = mergeReorderedVisibleIntoFullGroup(
        fullGroup: [a, b],
        reorderedVisible: [],
      );

      expect(result.map((x) => x.id), ['a', 'b']);
    });

    test(
        'matches by object identity, not by id, so accessories sharing '
        'an id (e.g. all "") are handled correctly', () {
      var a = Accessory(
          id: '',
          name: 'a',
          hashedPublicKey: 'hash-a',
          datePublished: null,
          hashesWithTS: {},
          locationHistory: [],
          lastBatteryStatus: null,
          additionalKeys: []);
      var c = Accessory(
          id: '',
          name: 'c',
          hashedPublicKey: 'hash-c',
          datePublished: null,
          hashesWithTS: {},
          locationHistory: [],
          lastBatteryStatus: null,
          additionalKeys: []);
      var b = Accessory(
          id: '',
          name: 'b',
          hashedPublicKey: 'hash-b',
          datePublished: null,
          hashesWithTS: {},
          locationHistory: [],
          lastBatteryStatus: null,
          additionalKeys: []);
      var d = Accessory(
          id: '',
          name: 'd',
          hashedPublicKey: 'hash-d',
          datePublished: null,
          hashesWithTS: {},
          locationHistory: [],
          lastBatteryStatus: null,
          additionalKeys: []);
      // c and d are filtered out (not in reorderedVisible), a and b are
      // dragged - all four share id: '', matching in-app-created
      // accessories, which never get a real id assigned.
      var result = mergeReorderedVisibleIntoFullGroup(
        fullGroup: [a, c, b, d],
        reorderedVisible: [b, a],
      );

      expect(result, [b, c, a, d]);
    });
  });
}
