import 'package:macless_haystack/map/map_tile_source.dart';
import 'package:test/test.dart';

void main() {
  group('mapTileSourceFromString', () {
    test('maps "osm" to the OpenStreetMap source', () {
      var source = mapTileSourceFromString(mapTileProviderOsmValue);
      expect(source.urlTemplate, contains('tile.openstreetmap.org'));
      expect(source.isDark, isFalse);
    });

    test('maps "opentopo" to the OpenTopoMap source', () {
      var source = mapTileSourceFromString(mapTileProviderOpenTopoValue);
      expect(source.urlTemplate, contains('opentopomap.org'));
      expect(source.isDark, isFalse);
    });

    test('maps "carto_voyager" to the CARTO Voyager source', () {
      var source = mapTileSourceFromString(mapTileProviderCartoVoyagerValue);
      expect(source.urlTemplate, contains('basemaps.cartocdn.com'));
      expect(source.urlTemplate, contains('voyager'));
      expect(source.isDark, isFalse);
    });

    test('maps "carto_dark" to the CARTO Dark Matter source, marked dark', () {
      var source = mapTileSourceFromString(mapTileProviderCartoDarkValue);
      expect(source.urlTemplate, contains('basemaps.cartocdn.com'));
      expect(source.isDark, isTrue);
    });

    test('falls back to OpenStreetMap for null', () {
      var source = mapTileSourceFromString(null);
      expect(source.urlTemplate, contains('tile.openstreetmap.org'));
    });

    test('falls back to OpenStreetMap for an unknown value', () {
      var source = mapTileSourceFromString('garbage');
      expect(source.urlTemplate, contains('tile.openstreetmap.org'));
    });

    test('appends the CARTO API key to a CARTO source when provided', () {
      var source = mapTileSourceFromString(
        mapTileProviderCartoVoyagerValue,
        cartoApiKey: 'my-key',
      );
      expect(source.urlTemplate, endsWith('?key=my-key'));
    });

    test('URL-encodes a CARTO API key containing special characters', () {
      var source = mapTileSourceFromString(
        mapTileProviderCartoDarkValue,
        cartoApiKey: 'a b&c',
      );
      expect(source.urlTemplate, endsWith('?key=a+b%26c'));
    });

    test('does not append a key for a non-CARTO source', () {
      var source = mapTileSourceFromString(
        mapTileProviderOsmValue,
        cartoApiKey: 'my-key',
      );
      expect(source.urlTemplate, isNot(contains('key=')));
    });

    test('does not append an empty CARTO API key', () {
      var source = mapTileSourceFromString(
        mapTileProviderCartoVoyagerValue,
        cartoApiKey: '',
      );
      expect(source.urlTemplate, isNot(contains('key=')));
    });
  });

  group('isCartoTileSource', () {
    test('is true for both CARTO values', () {
      expect(isCartoTileSource(mapTileProviderCartoVoyagerValue), isTrue);
      expect(isCartoTileSource(mapTileProviderCartoDarkValue), isTrue);
    });

    test('is false for non-CARTO values and null', () {
      expect(isCartoTileSource(mapTileProviderOsmValue), isFalse);
      expect(isCartoTileSource(mapTileProviderOpenTopoValue), isFalse);
      expect(isCartoTileSource(null), isFalse);
    });
  });
}
