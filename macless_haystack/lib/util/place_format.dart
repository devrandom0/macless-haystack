/// Joins two place-name parts (e.g. locality + administrative area) with
/// ", ", skipping either side that's null or empty instead of printing the
/// literal string "null" - geocoding results routinely leave one or both
/// unset depending on the queried location.
String? formatPlacePair(String? first, String? second) {
  var parts = [
    first,
    second,
  ].where((part) => part != null && part.isNotEmpty);
  if (parts.isEmpty) {
    return null;
  }
  return parts.join(', ');
}
