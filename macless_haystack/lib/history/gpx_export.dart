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
    // Fixed-point, not entry.location.latitude.toString() - Dart renders
    // any double smaller in magnitude than 1e-6 in exponential notation
    // (e.g. "-1.0e-7"), which GPX's xsd:decimal-based coordinate types do
    // not permit. 7 decimal places matches the ~1e-7 precision the FindMy
    // report decoding itself already works at (see correctCoordinate in
    // findMy/decrypt_reports.dart).
    var lat = entry.location.latitude.toStringAsFixed(7);
    var lon = entry.location.longitude.toStringAsFixed(7);
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
  // XML 1.0 forbids raw C0 control characters (other than tab/LF/CR)
  // outright - unlike '&'/'<'/etc. they can't be rescued by entity
  // escaping, so they're stripped instead.
  var withoutControlChars =
      value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');
  return withoutControlChars
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// The filename to use when exporting [accessoryName]'s history as GPX.
///
/// [Accessory.name] is free-form user input - it can also arrive via an
/// OpenHaystack JSON import with no length or character restrictions - so
/// this strips characters unsafe across common filesystems, drops leading
/// dots (which would make the file hidden on unix), and caps the length
/// well under filesystem limits, falling back to a generic name if
/// nothing usable remains.
String gpxFilenameFor(String accessoryName) {
  var cleaned = accessoryName
      .replaceAll(RegExp(r'[\x00-\x1f\x7f\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'^\.+'), '')
      .trim()
      // Collapse runs of replacement underscores (e.g. two adjacent
      // control characters) into one, and drop any left dangling at the
      // edges, rather than a name like "Keys__.gpx".
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  const maxLength = 60;
  if (cleaned.length > maxLength) {
    var cut = maxLength;
    // Don't slice a UTF-16 surrogate pair in half (e.g. many emoji).
    var isLeadSurrogate =
        cleaned.codeUnitAt(cut - 1) >= 0xD800 && cleaned.codeUnitAt(cut - 1) <= 0xDBFF;
    if (isLeadSurrogate) {
      cut -= 1;
    }
    cleaned = cleaned.substring(0, cut).trim();
  }

  if (cleaned.isEmpty) {
    cleaned = 'accessory';
  }

  return '${cleaned}_history.gpx';
}
