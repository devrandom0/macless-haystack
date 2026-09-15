import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:test/test.dart';

void main() {
  group('isLowOrWorse', () {
    test('ok is not low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.ok), isFalse);
    });

    test('medium is not low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.medium), isFalse);
    });

    test('unknown is not low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.unknown), isFalse);
    });

    test('null is not low-or-worse', () {
      expect(isLowOrWorse(null), isFalse);
    });

    test('low is low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.low), isTrue);
    });

    test('criticalLow is low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.criticalLow), isTrue);
    });
  });

  group('isMoreSevere', () {
    test('first alert (previous is null) is always more severe', () {
      expect(isMoreSevere(null, AccessoryBatteryStatus.low), isTrue);
      expect(isMoreSevere(null, AccessoryBatteryStatus.criticalLow), isTrue);
    });

    test('same severity is not more severe (no re-alert)', () {
      expect(
        isMoreSevere(
            AccessoryBatteryStatus.low, AccessoryBatteryStatus.low),
        isFalse,
      );
      expect(
        isMoreSevere(AccessoryBatteryStatus.criticalLow,
            AccessoryBatteryStatus.criticalLow),
        isFalse,
      );
    });

    test('escalating from low to criticalLow is more severe', () {
      expect(
        isMoreSevere(
            AccessoryBatteryStatus.low, AccessoryBatteryStatus.criticalLow),
        isTrue,
      );
    });

    test('de-escalating from criticalLow to low is not more severe', () {
      expect(
        isMoreSevere(
            AccessoryBatteryStatus.criticalLow, AccessoryBatteryStatus.low),
        isFalse,
      );
    });
  });
}
