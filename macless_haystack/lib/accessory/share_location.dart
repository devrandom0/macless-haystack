/// Builds a Google Maps link for [latitude]/[longitude] suitable for
/// sharing - opens directly to that point in Google Maps (web or app)
/// on whatever device receives it.
String buildLocationShareLink(double latitude, double longitude) {
  return 'https://maps.google.com/?q=$latitude,$longitude';
}
