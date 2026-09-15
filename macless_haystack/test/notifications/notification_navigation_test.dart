import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/notifications/notification_navigation.dart';
import 'package:test/test.dart';

void main() {
  Accessory buildAccessory(String id, LatLng? location) {
    var accessory = Accessory(
        id: id,
        name: 'Test $id',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: List.empty());
    accessory.lastLocation = location;
    return accessory;
  }

  test('resolves the location of a matching accessory', () {
    var target = buildAccessory('target', const LatLng(51.5, -0.1));
    var other = buildAccessory('other', const LatLng(1, 1));

    var result =
        resolveNotifiedAccessoryLocation('target', [other, target]);

    expect(result, const LatLng(51.5, -0.1));
  });

  test('returns null when no accessory matches the id', () {
    var other = buildAccessory('other', const LatLng(1, 1));

    var result = resolveNotifiedAccessoryLocation('missing', [other]);

    expect(result, isNull);
  });

  test('returns null when the matching accessory has no known location', () {
    var target = buildAccessory('target', null);

    var result = resolveNotifiedAccessoryLocation('target', [target]);

    expect(result, isNull);
  });
}
