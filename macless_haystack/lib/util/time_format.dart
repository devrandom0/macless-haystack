import 'package:universal_io/io.dart';

import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:intl/intl.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

enum TimeFormatPreference { system, h12, h24 }

/// Raw settings values for [timeFormatKey], shared with the settings tile so
/// the dropdown options and the parsing below can never drift apart.
const String timeFormatSystemValue = 'system';
const String timeFormatH12Value = '12h';
const String timeFormatH24Value = '24h';

/// Maps a raw settings value to a [TimeFormatPreference].
///
/// Anything other than the known [timeFormatH12Value]/[timeFormatH24Value]
/// values (including null) falls back to following the device locale,
/// matching this setting's default.
TimeFormatPreference timeFormatPreferenceFromString(String? value) {
  switch (value) {
    case timeFormatH12Value:
      return TimeFormatPreference.h12;
    case timeFormatH24Value:
      return TimeFormatPreference.h24;
    default:
      return TimeFormatPreference.system;
  }
}

/// Formats the time-of-day portion of [time] according to [preference].
///
/// 'h12'/'h24' force that clock style regardless of [locale]; 'system'
/// follows the locale's own convention, same as the app's previous behavior.
/// Falls back to a fixed, locale-independent format if [locale] isn't one
/// intl recognizes (e.g. a device reporting "POSIX" or an empty locale),
/// so a broken device locale never crashes formatting.
String formatTimeOfDay(
    DateTime time, TimeFormatPreference preference, String locale) {
  try {
    switch (preference) {
      case TimeFormatPreference.h12:
        return DateFormat('h:mm a', locale).format(time);
      case TimeFormatPreference.h24:
        return DateFormat.Hm(locale).format(time);
      case TimeFormatPreference.system:
        return DateFormat.jm(locale).format(time);
    }
  } catch (_) {
    return DateFormat('HH:mm').format(time);
  }
}

/// Formats the time-of-day portion of [time] using the user's configured
/// time format preference (Settings, key [timeFormatKey]).
String formatTime(DateTime time) {
  var preference = timeFormatPreferenceFromString(Settings.getValue<String>(
      timeFormatKey,
      defaultValue: timeFormatSystemValue));
  return formatTimeOfDay(time, preference, Platform.localeName);
}
