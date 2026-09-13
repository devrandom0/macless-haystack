import 'dart:math';

import 'package:flutter/material.dart';
import 'package:macless_haystack/accessory/accessory_icon_model.dart';

typedef IconChangeListener = void Function(String? newValue);

String describeAccessoryIconName(String iconName) {
  var stripped = iconName.endsWith('.fill')
      ? iconName.substring(0, iconName.length - '.fill'.length)
      : iconName;
  var spaced = stripped.replaceAll('.', ' ').replaceAll('_', ' ');
  spaced = spaced.replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}');
  if (spaced.isEmpty) return spaced;
  return spaced[0].toUpperCase() + spaced.substring(1).toLowerCase();
}

class AccessoryIconSelector extends StatelessWidget {
  /// The existing icon used previously.
  final String icon;
  /// The existing color used previously.
  final Color color;
  /// A callback being called when the icon changes.
  final IconChangeListener iconChanged;

  /// This show an icon selector.
  /// 
  /// The icon can be selected from a list of available icons.
  /// The icons are handled by the cupertino icon names.
  const AccessoryIconSelector({
    super.key,
    required this.icon,
    required this.color,
    required this.iconChanged,
  });

  /// Displays the icon selector with the [currentIcon] preselected in the [highlighColor].
  /// 
  /// The selected icon as a cupertino icon name is returned if the user selects an icon.
  /// Otherwise the selection is discarded and a null value is returned.
  static Future<String?> showIconSelection(BuildContext context, String currentIcon, Color highlighColor) async {
  return await showDialog<String>(
    context: context,
    builder: (BuildContext context) {
      return LayoutBuilder(
        builder: (context, constraints) => Dialog(
          child: GridView.count(
            primary: false,
            padding: const EdgeInsets.all(20),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            shrinkWrap: true,
            crossAxisCount: min((constraints.maxWidth / 80).floor(), 8),
            semanticChildCount: AccessoryIconModel.icons.length,
            children: AccessoryIconModel.icons
              .map((value) => Tooltip(
                message: describeAccessoryIconName(value),
                child: IconButton(
                  icon: Icon(AccessoryIconModel.mapIcon(value)),
                  color: value == currentIcon ? highlighColor : null,
                  onPressed: () { Navigator.pop(context, value); },
                ),
              )).toList(),
          ),
        ),
      );
    }
  );
}

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // surfaceContainerHighest is the M3 token designed to pair with the
        // IconButton's default onSurfaceVariant foreground; the previous
        // hardcoded grey left the icon invisible in the dark theme.
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: () async {
          String? selectedIcon = await showIconSelection(context, icon, color);
          if (selectedIcon != null) {
            iconChanged(selectedIcon);
          }
        },
        icon: Icon(AccessoryIconModel.mapIcon(icon)),
      ),
    );
  }
}
