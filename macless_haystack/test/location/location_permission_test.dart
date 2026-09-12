import 'package:location/location.dart';
import 'package:macless_haystack/location/location_permission.dart';
import 'package:test/test.dart';

void main() {
  test('treats a full grant as granted', () {
    expect(isLocationPermissionGranted(PermissionStatus.granted), isTrue);
  });

  test('treats a coarse-only grant as granted', () {
    expect(
        isLocationPermissionGranted(PermissionStatus.grantedLimited), isTrue);
  });

  test('does not treat a denial as granted', () {
    expect(isLocationPermissionGranted(PermissionStatus.denied), isFalse);
  });

  test('does not treat a permanent denial as granted', () {
    expect(
        isLocationPermissionGranted(PermissionStatus.deniedForever), isFalse);
  });
}
