import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
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

  group('popupPlacementFor', () {
    // flutter_map positions a Marker's box as
    // [point - 0.5*W*(1-a), point + 0.5*W*(1+a)] for alignment.x=a - the
    // actual invariant this function exists to guarantee, so tests check
    // the resulting box stays on screen rather than hardcoding expected
    // alignment values that would just repeat the implementation's own math.
    ({double left, double right}) boxFor(
        PopupPlacement placement, double screenX, double popupWidth) {
      var left = screenX - 0.5 * popupWidth * (1 - placement.horizontalAlignment);
      return (left: left, right: left + popupWidth);
    }

    test('shows above and centered when there is room on every side', () {
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(200, 400),
        viewportSize: const Size(400, 800),
      );

      expect(placement.showAbove, isTrue);
      expect(placement.maxHeight, 320.0);
      expect(placement.horizontalAlignment, 0.0);
    });

    test('flips below when there is no room above but room below', () {
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(200, 50),
        viewportSize: const Size(400, 800),
      );

      expect(placement.showAbove, isFalse);
      expect(placement.maxHeight, 320.0);
    });

    test('stays above and shrinks when above has more room than below but neither fits fully', () {
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(200, 300),
        viewportSize: const Size(400, 500),
      );

      expect(placement.showAbove, isTrue);
      expect(placement.maxHeight, lessThan(320.0));
    });

    test('shrinks to fit, never below the minimum, when neither side has full room', () {
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(200, 60),
        viewportSize: const Size(400, 120),
        minHeight: 80,
      );

      expect(placement.maxHeight, greaterThanOrEqualTo(80.0));
      expect(placement.maxHeight, lessThan(320.0));
    });

    test('keeps the popup box on screen when the marker is near the right edge', () {
      const viewport = Size(400, 800);
      const popupWidth = 250.0;
      const margin = 16.0;
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(370, 400),
        viewportSize: viewport,
        popupWidth: popupWidth,
        margin: margin,
      );

      var box = boxFor(placement, 370, popupWidth);
      expect(box.left, greaterThanOrEqualTo(margin - 0.01));
      expect(box.right, lessThanOrEqualTo(viewport.width - margin + 0.01));
    });

    test('keeps the popup box on screen when the marker is near the left edge', () {
      const viewport = Size(400, 800);
      const popupWidth = 250.0;
      const margin = 16.0;
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(30, 400),
        viewportSize: viewport,
        popupWidth: popupWidth,
        margin: margin,
      );

      var box = boxFor(placement, 30, popupWidth);
      expect(box.left, greaterThanOrEqualTo(margin - 0.01));
      expect(box.right, lessThanOrEqualTo(viewport.width - margin + 0.01));
    });

    test('keeps the popup box on screen for a marker only partially shifted', () {
      const viewport = Size(400, 800);
      const popupWidth = 250.0;
      const margin = 16.0;
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(350, 400),
        viewportSize: viewport,
        popupWidth: popupWidth,
        margin: margin,
      );

      expect(placement.horizontalAlignment, greaterThan(-1.0));
      expect(placement.horizontalAlignment, lessThan(0.0));
      var box = boxFor(placement, 350, popupWidth);
      expect(box.left, greaterThanOrEqualTo(margin - 0.01));
      expect(box.right, lessThanOrEqualTo(viewport.width - margin + 0.01));
    });

    test('does not center-clamp when the marker is comfortably centered', () {
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(200, 400),
        viewportSize: const Size(400, 800),
      );

      expect(placement.horizontalAlignment, 0.0);
    });

    test('does not throw when the viewport is narrower than the popup plus margins', () {
      var placement = popupPlacementFor(
        markerScreenPoint: const Offset(50, 400),
        viewportSize: const Size(200, 800),
      );

      expect(placement.horizontalAlignment, inInclusiveRange(-1.0, 1.0));
    });
  });

  group('clusterAbsorbedSelection', () {
    Marker markerFor(String id) => Marker(
          key: ValueKey(id),
          point: const LatLng(0, 0),
          child: const SizedBox(),
        );

    test('is false when nothing is selected', () {
      var result = clusterAbsorbedSelection([markerFor('a')], null);

      expect(result, isFalse);
    });

    test('is false when the selected accessory is not in the merged markers',
        () {
      var result =
          clusterAbsorbedSelection([markerFor('a'), markerFor('b')], 'c');

      expect(result, isFalse);
    });

    test('is true when the selected accessory is among the merged markers',
        () {
      var result =
          clusterAbsorbedSelection([markerFor('a'), markerFor('b')], 'b');

      expect(result, isTrue);
    });
  });

  group('accessoryForMarker', () {
    Marker markerFor(String id) => Marker(
          key: ValueKey(id),
          point: const LatLng(0, 0),
          child: const SizedBox(),
        );

    test('finds the accessory whose id matches the marker key', () {
      var accessories = [_accessory(id: 'a'), _accessory(id: 'b')];

      var result = accessoryForMarker(accessories, markerFor('b'));

      expect(result, same(accessories[1]));
    });

    test('returns null when no accessory matches the marker key', () {
      var accessories = [_accessory(id: 'a')];

      var result = accessoryForMarker(accessories, markerFor('missing'));

      expect(result, isNull);
    });

    test('returns null when the marker has no ValueKey<String>', () {
      var accessories = [_accessory(id: 'a')];
      var marker = Marker(point: const LatLng(0, 0), child: const SizedBox());

      var result = accessoryForMarker(accessories, marker);

      expect(result, isNull);
    });
  });
}
