import 'package:flutter/material.dart';
import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:test/test.dart';

void main() {
  Accessory buildAccessory({required Color color}) {
    return Accessory(
        id: '1',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: List.empty(),
        color: color);
  }

  Accessory buildAccessoryWithBattery({
    AccessoryBatteryStatus? lastBatteryStatus,
    AccessoryBatteryStatus? lastNotifiedBatteryStatus,
  }) {
    final accessory = Accessory(
        id: '1',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: lastBatteryStatus,
        additionalKeys: List.empty());
    accessory.lastNotifiedBatteryStatus = lastNotifiedBatteryStatus;
    return accessory;
  }

  test('toJson/fromJson round-trips the color unchanged', () {
    final accessory = buildAccessory(color: const Color(0xFF3A7BD5));

    final restored = Accessory.fromJson(accessory.toJson());

    expect(restored.color, accessory.color);
  });

  test('toJson encodes color as an 8-digit hex ARGB string', () {
    final accessory = buildAccessory(color: const Color(0xFF3A7BD5));

    expect(accessory.toJson()['color'], 'ff3a7bd5');
  });

  test('toJson/fromJson round-trips lastNotifiedBatteryStatus when set', () {
    final accessory = buildAccessoryWithBattery(
      lastBatteryStatus: AccessoryBatteryStatus.low,
      lastNotifiedBatteryStatus: AccessoryBatteryStatus.low,
    );

    final restored = Accessory.fromJson(accessory.toJson());

    expect(restored.lastNotifiedBatteryStatus, AccessoryBatteryStatus.low);
  });

  test('toJson omits lastNotifiedBatteryStatus when null', () {
    final accessory = buildAccessoryWithBattery();

    expect(accessory.toJson().containsKey('lastNotifiedBatteryStatus'), isFalse);
  });

  test('fromJson leaves lastNotifiedBatteryStatus null when absent', () {
    final accessory = buildAccessoryWithBattery();

    final restored = Accessory.fromJson(accessory.toJson());

    expect(restored.lastNotifiedBatteryStatus, isNull);
  });

  test('clone copies lastNotifiedBatteryStatus', () {
    final accessory = buildAccessoryWithBattery(
      lastNotifiedBatteryStatus: AccessoryBatteryStatus.criticalLow,
    );

    final cloned = accessory.clone();

    expect(cloned.lastNotifiedBatteryStatus, AccessoryBatteryStatus.criticalLow);
  });
}
