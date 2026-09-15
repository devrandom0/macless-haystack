import 'package:flutter/foundation.dart';

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
