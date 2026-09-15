import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';

/// Connects "a low-battery notification was tapped" to "the UI should jump
/// to that accessory." A notification service has no reason to know about
/// tab indices or map controllers, and the dashboard/map widgets have no
/// reason to know about notification payloads - this is the one shared
/// piece of state between them.
class NotificationNavigation {
  NotificationNavigation._();

  /// The id of the accessory to jump to, or null when there's nothing
  /// pending. Set by [BatteryNotificationService]'s tap handler; cleared by
  /// whichever widget consumes it (see AccessoryMapListVertical).
  static final ValueNotifier<String?> pendingAccessoryId =
      ValueNotifier<String?>(null);
}

/// The location to center the map on for the accessory a tapped low-battery
/// notification referred to, or null if it no longer exists in [accessories]
/// or has no known location yet.
LatLng? resolveNotifiedAccessoryLocation(
  String accessoryId,
  Iterable<Accessory> accessories,
) {
  for (var accessory in accessories) {
    if (accessory.id == accessoryId) {
      return accessory.lastLocation;
    }
  }
  return null;
}
