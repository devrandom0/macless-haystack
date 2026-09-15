import 'package:macless_haystack/accessory/accessory_model.dart';

/// Builds a GPX 1.1 track document from [entries] (already sorted
/// chronologically, e.g. via [Accessory.getSortedLocationHistory]), for
/// exporting a single accessory's location history to standard mapping
/// tools. Each entry's [Pair.start] - when the accessory was first seen at
/// that location - is used as the point's time, since GPX only supports
/// one timestamp per track point.
String buildGpxDocument(
  String accessoryName,
  List<Pair<dynamic, dynamic>> entries,
) {
  var trackPoints = entries.map((entry) {
    var lat = entry.location.latitude;
    var lon = entry.location.longitude;
    var time = entry.start.toUtc().toIso8601String();
    return '    <trkpt lat="$lat" lon="$lon"><time>$time</time></trkpt>';
  }).join('\n');

  return '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Macless Haystack" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>${_escapeXml(accessoryName)}</name>
    <trkseg>
$trackPoints
    </trkseg>
  </trk>
</gpx>
''';
}

/// Escapes the characters XML requires escaped in text content.
String _escapeXml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
