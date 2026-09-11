import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/map/map.dart';
import 'package:test/test.dart';

Accessory _accessory({LatLng? lastLocation, bool isActive = true}) {
  return Accessory(
    id: 'a',
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
}
