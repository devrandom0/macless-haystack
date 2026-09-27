import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';

/// A persisted boolean setting shown as a stock Material [SwitchListTile].
///
/// Replaces flutter_settings_screens' SwitchSettingsTile, which forces the
/// thumb to the primary color in every state, so on a Material 3 theme the
/// thumb disappears into the primary-colored "on" track.
class PreferenceSwitchTile extends StatelessWidget {
  final String settingKey;
  final bool defaultValue;
  final String title;
  final String? subtitle;
  final ValueChanged<bool>? onChange;

  const PreferenceSwitchTile({
    super.key,
    required this.settingKey,
    required this.title,
    this.defaultValue = false,
    this.subtitle,
    this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return ValueChangeObserver<bool>(
      cacheKey: settingKey,
      defaultValue: defaultValue,
      builder: (context, value, onChanged) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            value: value,
            title: Text(title),
            subtitle: subtitle == null ? null : Text(subtitle!),
            onChanged: (newValue) {
              onChanged(newValue);
              onChange?.call(newValue);
            },
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
