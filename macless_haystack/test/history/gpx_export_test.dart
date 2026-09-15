import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/history/gpx_export.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  group('buildGpxDocument', () {
    test('produces a valid GPX 1.1 document with the right root attributes', () {
      var doc = buildGpxDocument('Keys', []);

      var xml = XmlDocument.parse(doc);
      var gpx = xml.rootElement;
      expect(gpx.name.local, 'gpx');
      expect(gpx.getAttribute('version'), '1.1');
      expect(gpx.getAttribute('creator'), 'Macless Haystack');
    });

    test('includes the accessory name as the track name', () {
      var doc = buildGpxDocument('Keys', []);

      var xml = XmlDocument.parse(doc);
      var name = xml.findAllElements('name').first;
      expect(name.innerText, 'Keys');
    });

    test('XML-escapes an accessory name with special characters', () {
      var doc = buildGpxDocument('Tom & Jerry <2>', []);

      // Parsing succeeds only if the name was properly escaped - an
      // unescaped '&' or '<' here would make this an invalid document.
      var xml = XmlDocument.parse(doc);
      var name = xml.findAllElements('name').first;
      expect(name.innerText, 'Tom & Jerry <2>');
    });

    test('an empty entry list produces a track with no points', () {
      var doc = buildGpxDocument('Keys', []);

      var xml = XmlDocument.parse(doc);
      expect(xml.findAllElements('trkpt'), isEmpty);
    });

    test('one entry produces one trkpt with correct lat/lon/time', () {
      var entries = [
        Pair<dynamic, dynamic>(
          const LatLng(51.5074, -0.1278),
          DateTime.utc(2026, 1, 1, 8, 30),
          DateTime.utc(2026, 1, 1, 9, 0),
        ),
      ];

      var doc = buildGpxDocument('Keys', entries);

      var xml = XmlDocument.parse(doc);
      var trkpts = xml.findAllElements('trkpt').toList();
      expect(trkpts, hasLength(1));
      expect(trkpts.first.getAttribute('lat'), '51.5074');
      expect(trkpts.first.getAttribute('lon'), '-0.1278');
      var time = trkpts.first.findElements('time').first.innerText;
      expect(time, '2026-01-01T08:30:00.000Z');
    });

    test('multiple entries produce trkpts in the given order', () {
      var entries = [
        Pair<dynamic, dynamic>(
          const LatLng(1, 1),
          DateTime.utc(2026, 1, 1),
          DateTime.utc(2026, 1, 1, 1),
        ),
        Pair<dynamic, dynamic>(
          const LatLng(2, 2),
          DateTime.utc(2026, 1, 2),
          DateTime.utc(2026, 1, 2, 1),
        ),
        Pair<dynamic, dynamic>(
          const LatLng(3, 3),
          DateTime.utc(2026, 1, 3),
          DateTime.utc(2026, 1, 3, 1),
        ),
      ];

      var doc = buildGpxDocument('Keys', entries);

      var xml = XmlDocument.parse(doc);
      var lats = xml
          .findAllElements('trkpt')
          .map((e) => e.getAttribute('lat'))
          .toList();
      expect(lats, ['1.0', '2.0', '3.0']);
    });
  });
}
