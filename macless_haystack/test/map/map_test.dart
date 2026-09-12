import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/map/map.dart';
import 'package:test/test.dart';

Accessory _accessory(
    {String id = 'a', LatLng? lastLocation, bool isActive = true}) {
  return Accessory(
    id: id,
    name: 'Test',
    hashedPublicKey: 'hash',
    datePublished: DateTime.now(),
    isActive: isActive,
    lastLocation: lastLocation,
    hashesWithTS: {},
    locationHistory: [],
    lastBatteryStatus: null,
    additionalKeys: [],
  );
}

void main() {
  test('does not fit when already fitted once', () {
    var accessories = [_accessory(lastLocation: const LatLng(10, 10))];

    var result = shouldFitToAccessoryLocations(accessories, true);

    expect(result, isFalse);
  });

  test('does not fit when no accessory has a location yet', () {
    var accessories = [_accessory(lastLocation: null)];

    var result = shouldFitToAccessoryLocations(accessories, false);

    expect(result, isFalse);
  });

  test('fits when an active accessory has a location and not yet fitted', () {
    var accessories = [_accessory(lastLocation: const LatLng(10, 10))];

    var result = shouldFitToAccessoryLocations(accessories, false);

    expect(result, isTrue);
  });

  test('ignores inactive accessories', () {
    var accessories = [
      _accessory(lastLocation: const LatLng(10, 10), isActive: false)
    ];

    var result = shouldFitToAccessoryLocations(accessories, false);

    expect(result, isFalse);
  });

  test('fits once one of several accessories has a location', () {
    var accessories = [
      _accessory(lastLocation: null),
      _accessory(lastLocation: const LatLng(10, 10)),
    ];

    var result = shouldFitToAccessoryLocations(accessories, false);

    expect(result, isTrue);
  });

  group('selectedAccessory', () {
    test('returns null when no id is selected', () {
      var accessories = [_accessory(lastLocation: const LatLng(10, 10))];

      var result = selectedAccessory(accessories, null);

      expect(result, isNull);
    });

    test('returns null when the selected id is not found', () {
      var accessories = [_accessory(lastLocation: const LatLng(10, 10))];

      var result = selectedAccessory(accessories, 'missing');

      expect(result, isNull);
    });

    test('returns null when the selected accessory was deactivated', () {
      var accessories = [
        _accessory(lastLocation: const LatLng(10, 10), isActive: false)
      ];

      var result = selectedAccessory(accessories, 'a');

      expect(result, isNull);
    });

    test('returns null when the selected accessory lost its location', () {
      var accessories = [_accessory(lastLocation: null)];

      var result = selectedAccessory(accessories, 'a');

      expect(result, isNull);
    });

    test('returns the accessory when it is active with a known location',
        () {
      var accessories = [_accessory(lastLocation: const LatLng(10, 10))];

      var result = selectedAccessory(accessories, 'a');

      expect(result, same(accessories.first));
    });
  });
}
