import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:macless_haystack/notifications/battery_notification_service.dart';
import 'package:test/test.dart';

void main() {
  group('batteryNotificationTitle', () {
    test('low battery title names the accessory', () {
      expect(
        batteryNotificationTitle('Keys', AccessoryBatteryStatus.low),
        'Keys battery is low',
      );
    });

    test('criticalLow battery title names the accessory', () {
      expect(
        batteryNotificationTitle('Keys', AccessoryBatteryStatus.criticalLow),
        'Keys battery is critically low',
      );
    });
  });

  group('batteryNotificationBody', () {
    test('low battery body suggests recharging soon', () {
      expect(
        batteryNotificationBody(AccessoryBatteryStatus.low),
        'Consider replacing or recharging its battery soon.',
      );
    });

    test('criticalLow battery body warns reporting may stop', () {
      expect(
        batteryNotificationBody(AccessoryBatteryStatus.criticalLow),
        'It may stop reporting its location soon.',
      );
    });
  });
}
