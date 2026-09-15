import 'package:flutter/material.dart';

enum AccessoryBatteryStatus {
  ok,     // Battery is currently charging
  medium,  // Battery is currently discharging
  low,         // Battery is fully charged
  criticalLow,    // Battery status is unknown or not applicable
  unknown       // Battery status is unknown or not applicable
}

/// Displays the icon for an accessory's [status], using the same
/// icon/color mapping wherever a battery indicator is shown.
class AccessoryBatteryIcon extends StatelessWidget {
  final AccessoryBatteryStatus? status;
  final double size;

  const AccessoryBatteryIcon({
    super.key,
    required this.status,
    this.size = 13,
  });

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case AccessoryBatteryStatus.ok:
        return Icon(Icons.battery_full, color: Colors.green, size: size);
      case AccessoryBatteryStatus.medium:
        return Icon(Icons.battery_3_bar, color: Colors.orange, size: size);
      case AccessoryBatteryStatus.low:
        return Icon(Icons.battery_1_bar, color: Colors.red, size: size);
      case AccessoryBatteryStatus.criticalLow:
        return Icon(Icons.battery_alert, color: Colors.red, size: size);
      default:
        return SizedBox(width: size);
    }
  }
}

/// Whether [status] represents a battery level worth alerting on.
///
/// [AccessoryBatteryStatus.unknown] is declared after [criticalLow] in the
/// enum but means "no data," not "worse than critical" - it must never be
/// treated as low-or-worse, so this checks the two real low states
/// explicitly rather than comparing by `Enum.index`.
bool isLowOrWorse(AccessoryBatteryStatus? status) {
  return status == AccessoryBatteryStatus.low ||
      status == AccessoryBatteryStatus.criticalLow;
}

/// Whether [status] is strictly more severe than [previous].
///
/// Only meaningful when [status] is low-or-worse; callers are expected to
/// have already checked that. [previous] is nullable to represent "never
/// alerted yet," which is always more severe than any low state.
bool isMoreSevere(
  AccessoryBatteryStatus? previous,
  AccessoryBatteryStatus status,
) {
  if (previous == null) return true;
  const severityOrder = {
    AccessoryBatteryStatus.low: 0,
    AccessoryBatteryStatus.criticalLow: 1,
  };
  return (severityOrder[status] ?? -1) > (severityOrder[previous] ?? -1);
}
