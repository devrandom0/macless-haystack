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

/// Whether [value] identifies one of the CARTO tile sources, which - unlike
/// OpenStreetMap and OpenTopoMap - now require an API key on every request
/// (see [mapTileSourceFromString]).
bool isCartoTileSource(String? value) {
  return value == mapTileProviderCartoVoyagerValue ||
      value == mapTileProviderCartoDarkValue;
}

/// Maps a raw settings value to a [MapTileSource], falling back to
/// OpenStreetMap (this setting's default) for anything unrecognized.
///
/// CARTO's free basemaps now require an API key appended to every tile
/// request (https://carto.com/basemaps/apikey/) - without one, CARTO serves
/// tiles watermarked "API KEY REQUIRED" instead of an error, so [cartoApiKey]
/// is appended whenever [value] is a CARTO source and a key was provided.
MapTileSource mapTileSourceFromString(String? value, {String? cartoApiKey}) {
  var source = _mapTileSources[value] ?? _mapTileSources[mapTileProviderOsmValue]!;
  if (isCartoTileSource(value) && cartoApiKey != null && cartoApiKey.isNotEmpty) {
    return MapTileSource(
      urlTemplate:
          '${source.urlTemplate}?key=${Uri.encodeQueryComponent(cartoApiKey)}',
      subdomains: source.subdomains,
      attributionText: source.attributionText,
      isDark: source.isDark,
    );
  }
  return source;
}
