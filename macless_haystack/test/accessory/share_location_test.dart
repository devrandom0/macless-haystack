import 'package:macless_haystack/accessory/share_location.dart';
import 'package:test/test.dart';

void main() {
  test('builds a Google Maps link for a normal coordinate pair', () {
    expect(buildLocationShareLink(52.520008, 13.404954),
        'https://maps.google.com/?q=52.520008,13.404954');
  });

  test('preserves the minus sign for southern/western coordinates', () {
    expect(buildLocationShareLink(-33.868820, -70.629730),
        'https://maps.google.com/?q=-33.86882,-70.62973');
  });

  test('does not truncate or round a high-precision GPS coordinate', () {
    expect(buildLocationShareLink(37.42199829101562, -122.0840015411377),
        'https://maps.google.com/?q=37.42199829101562,-122.0840015411377');
  });
}
