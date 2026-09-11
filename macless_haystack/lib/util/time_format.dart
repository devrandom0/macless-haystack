import 'package:universal_io/io.dart';

import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:intl/intl.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

enum TimeFormatPreference { system, h12, h24 }

/// Maps the raw settings value for [timeFormatKey] to a [TimeFormatPreference].
///
/// Anything other than the known '12h'/'24h' values (including null) falls
/// back to following the device locale, matching this setting's default.
TimeFormatPreference timeFormatPreferenceFromString(String? value) {
  switch (value) {
    case '12h':
      return TimeFormatPreference.h12;
    case '24h':
      return TimeFormatPreference.h24;
    default:
      return TimeFormatPreference.system;
  }
}

/// Formats the time-of-day portion of [time] according to [preference].
///
/// 'h12'/'h24' force that clock style regardless of [locale]; 'system'
/// follows the locale's own convention, same as the app's previous behavior.
String formatTimeOfDay(
    DateTime time, TimeFormatPreference preference, String locale) {
  switch (preference) {
    case TimeFormatPreference.h12:
      return DateFormat('h:mm a', locale).format(time);
    case TimeFormatPreference.h24:
      return DateFormat('HH:mm', locale).format(time);
    case TimeFormatPreference.system:
      return DateFormat.jm(locale).format(time);
  }
}

/// Formats the time-of-day portion of [time] using the user's configured
/// time format preference (Settings, key [timeFormatKey]).
String formatTime(DateTime time) {
  var preference = timeFormatPreferenceFromString(
      Settings.getValue<String>(timeFormatKey, defaultValue: 'system'));
  return formatTimeOfDay(time, preference, Platform.localeName);
}
