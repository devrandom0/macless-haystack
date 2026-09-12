import 'package:flutter/material.dart';

/// Raw settings values for [themeModeKey], shared with the settings tile so
/// the dropdown options and the parsing below can never drift apart.
const String themeModeSystemValue = 'system';
const String themeModeLightValue = 'light';
const String themeModeDarkValue = 'dark';

/// Maps a raw settings value to a [ThemeMode].
///
/// Anything other than the known [themeModeLightValue]/[themeModeDarkValue]
/// values (including null) falls back to following the system setting,
/// matching this setting's default.
ThemeMode themeModeFromString(String? value) {
  switch (value) {
    case themeModeLightValue:
      return ThemeMode.light;
    case themeModeDarkValue:
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}
