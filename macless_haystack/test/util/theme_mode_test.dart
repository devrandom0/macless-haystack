import 'package:flutter/material.dart';
import 'package:macless_haystack/util/theme_mode.dart';
import 'package:test/test.dart';

void main() {
  group('themeModeFromString', () {
    test('maps "light" to ThemeMode.light', () {
      expect(themeModeFromString(themeModeLightValue), ThemeMode.light);
    });

    test('maps "dark" to ThemeMode.dark', () {
      expect(themeModeFromString(themeModeDarkValue), ThemeMode.dark);
    });

    test('maps "system" to ThemeMode.system', () {
      expect(themeModeFromString(themeModeSystemValue), ThemeMode.system);
    });

    test('maps null to ThemeMode.system', () {
      expect(themeModeFromString(null), ThemeMode.system);
    });

    test('maps an unknown value to ThemeMode.system', () {
      expect(themeModeFromString('garbage'), ThemeMode.system);
    });
  });
}
