import 'package:location/location.dart';

/// Whether [status] lets the app read the device's location.
///
/// location 10.0.0 started reporting [PermissionStatus.grantedLimited] for a
/// coarse-only grant on Android 12+ (API 31+); before that the same grant
/// came back as [PermissionStatus.granted]. Treat both as granted so the app
/// still gets an approximate location instead of tearing down the stream.
bool isLocationPermissionGranted(PermissionStatus status) =>
    status == PermissionStatus.granted ||
    status == PermissionStatus.grantedLimited;
