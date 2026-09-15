import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart';
import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/notifications/notification_navigation.dart';

const _channelId = 'low_battery';
const _channelName = 'Low battery';
const _channelDescription =
    'Alerts when a tracked accessory\'s battery is low or critically low.';

/// The notification title for [status] on an accessory named [accessoryName].
///
/// Only meaningful for [AccessoryBatteryStatus.low] and
/// [AccessoryBatteryStatus.criticalLow] - callers only invoke this after
/// already checking [isLowOrWorse].
String batteryNotificationTitle(
  String accessoryName,
  AccessoryBatteryStatus status,
) {
  return status == AccessoryBatteryStatus.criticalLow
      ? '$accessoryName battery is critically low'
      : '$accessoryName battery is low';
}

/// The notification body for [status]. See [batteryNotificationTitle].
String batteryNotificationBody(AccessoryBatteryStatus status) {
  return status == AccessoryBatteryStatus.criticalLow
      ? 'It may stop reporting its location soon.'
      : 'Consider replacing or recharging its battery soon.';
}

/// Shows an Android system notification when a tracked accessory's battery
/// drops to low or critically low. See
/// docs/superpowers/specs/2026-09-15-low-battery-notifications-design.md.
class BatteryNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  var logger = Logger(printer: PrettyPrinter(methodCount: 0));
  bool _initialized = false;

  /// Creates the Android notification channel, requests the
  /// POST_NOTIFICATIONS runtime permission (Android 13+; a no-op on older
  /// versions), and seeds [NotificationNavigation.pendingAccessoryId] if
  /// the app process was launched by tapping a low-battery notification
  /// from a fully killed state. Safe to call more than once - later calls
  /// are ignored.
  Future<void> init() async {
    if (_initialized) return;
    try {
      const androidSettings = AndroidInitializationSettings(
        '@drawable/ic_notification',
      );
      await _plugin.initialize(
        settings: const InitializationSettings(android: androidSettings),
        onDidReceiveNotificationResponse: (response) {
          final accessoryId = response.payload;
          if (accessoryId != null) {
            NotificationNavigation.pendingAccessoryId.value = accessoryId;
          }
        },
      );

      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
      );
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(channel);

      // Deliberately not awaited: on Android 13+, if the permission
      // hasn't been granted yet, this blocks on the user's response to
      // the system permission dialog. Awaiting it here would block
      // main()'s call to this method, which runs before runApp() - the
      // first frame would never render behind a bare launch theme until
      // the user answers the dialog.
      unawaited(androidPlugin?.requestNotificationsPermission());

      // onDidReceiveNotificationResponse above only fires while the app
      // process is already alive (foreground or background) - a tap that
      // launches the app from a fully killed state arrives here instead.
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      final launchPayload = launchDetails?.notificationResponse?.payload;
      if (launchDetails?.didNotificationLaunchApp == true &&
          launchPayload != null) {
        NotificationNavigation.pendingAccessoryId.value = launchPayload;
      }

      _initialized = true;
    } catch (e) {
      logger.e('Failed to initialize battery notification service: $e');
    }
  }

  /// Shows a low-battery notification for [accessory]. [accessory.lastBatteryStatus]
  /// must already be [AccessoryBatteryStatus.low] or
  /// [AccessoryBatteryStatus.criticalLow] - callers are expected to have
  /// checked this via [isLowOrWorse] before calling.
  Future<void> notifyLowBattery(Accessory accessory) async {
    final status = accessory.lastBatteryStatus;
    if (status == null || !isLowOrWorse(status)) return;

    try {
      const androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      await _plugin.show(
        id: accessory.id.hashCode,
        title: batteryNotificationTitle(accessory.name, status),
        body: batteryNotificationBody(status),
        notificationDetails: const NotificationDetails(
          android: androidDetails,
        ),
        payload: accessory.id,
      );
    } catch (e) {
      logger.e('Failed to show low-battery notification: $e');
    }
  }
}
