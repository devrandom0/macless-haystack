/// Raw settings values for [mapTileProviderKey] (see
/// preferences/user_preferences_model.dart), shared with the settings
/// dropdown so its options and the parsing below can never drift apart.
const String mapTileProviderOsmValue = 'osm';
const String mapTileProviderOpenTopoValue = 'opentopo';
const String mapTileProviderCartoVoyagerValue = 'carto_voyager';
const String mapTileProviderCartoDarkValue = 'carto_dark';

/// A free, no-API-key-required raster tile source for flutter_map's
/// TileLayer.
class MapTileSource {
  final String urlTemplate;
  final List<String> subdomains;
  final String attributionText;

  /// Whether these tiles are already dark. The map applies a color
  /// inversion to fake a dark map over light (the default) tiles when the
  /// app is in dark mode - a source that's dark on its own must skip that,
  /// or it gets inverted back towards light.
  final bool isDark;

  const MapTileSource({
    required this.urlTemplate,
    this.subdomains = const [],
    required this.attributionText,
    this.isDark = false,
  });
}

const Map<String, MapTileSource> _mapTileSources = {
  mapTileProviderOsmValue: MapTileSource(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attributionText: '© OpenStreetMap contributors',
  ),
  mapTileProviderOpenTopoValue: MapTileSource(
    urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    subdomains: ['a', 'b', 'c'],
    attributionText:
        'Map data: © OpenStreetMap contributors, SRTM | '
        'Map style: © OpenTopoMap (CC-BY-SA)',
  ),
  mapTileProviderCartoVoyagerValue: MapTileSource(
    urlTemplate:
        'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/'
        '{z}/{x}/{y}{r}.png',
    subdomains: ['a', 'b', 'c', 'd'],
    attributionText: '© OpenStreetMap contributors © CARTO',
  ),
  mapTileProviderCartoDarkValue: MapTileSource(
    urlTemplate:
        'https://{s}.basemaps.cartocdn.com/rastertiles/dark_all/'
        '{z}/{x}/{y}{r}.png',
    subdomains: ['a', 'b', 'c', 'd'],
    attributionText: '© OpenStreetMap contributors © CARTO',
    isDark: true,
  ),
};

/// Maps a raw settings value to a [MapTileSource], falling back to
/// OpenStreetMap (this setting's default) for anything unrecognized.
MapTileSource mapTileSourceFromString(String? value) {
  return _mapTileSources[value] ?? _mapTileSources[mapTileProviderOsmValue]!;
}
