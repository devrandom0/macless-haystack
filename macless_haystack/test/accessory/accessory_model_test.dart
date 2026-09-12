import 'package:flutter/material.dart';
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

  test('toJson/fromJson round-trips the color unchanged', () {
    final accessory = buildAccessory(color: const Color(0xFF3A7BD5));

    final restored = Accessory.fromJson(accessory.toJson());

    expect(restored.color, accessory.color);
  });

  test('toJson encodes color as an 8-digit hex ARGB string', () {
    final accessory = buildAccessory(color: const Color(0xFF3A7BD5));

    expect(accessory.toJson()['color'], 'ff3a7bd5');
  });
}
