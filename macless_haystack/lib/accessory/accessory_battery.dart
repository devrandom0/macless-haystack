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
