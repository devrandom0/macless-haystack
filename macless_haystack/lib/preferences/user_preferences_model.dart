import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const locationPreferenceKnownKey = 'LOCATION_PREFERENCE_KNOWN';
const locationAccessWantedKey = 'LOCATION_PREFERENCE_WANTED';
const fetchLocationOnStartupKey = 'FETCH_LOCATION_ON_STARTUP';
const endpointUrl = 'HAYSTACK_URL';
const String endpointUser = 'HAYSTACK_USER';
const String endpointPass = 'HAYSTACK_PASS';
const String numberOfDaysToFetch = 'NUMBER_OF_DAYS';
const String timeFormatKey = 'TIME_FORMAT';
const String themeModeKey = 'THEME_MODE';
const String appleAuthEnabledKey = 'APPLE_AUTH_ENABLED';
const String compactAccessoryListKey = 'COMPACT_ACCESSORY_LIST';
const String mapTileProviderKey = 'MAP_TILE_PROVIDER';
const String cartoApiKeyKey = 'CARTO_API_KEY';
const String lowBatteryNotificationsEnabledKey =
    'LOW_BATTERY_NOTIFICATIONS_ENABLED';

class UserPreferences extends ChangeNotifier {
  /// If these settings are initialized.
  bool initialized = false;

  /// The shared preferences storage.
  SharedPreferences? _prefs;

  /// Manages information about the users preferences.
  UserPreferences() {
    _initializeAsync();
  }

  /// Initialize shared preferences access
  void _initializeAsync() async {
    _prefs = await SharedPreferences.getInstance();

    // For Debugging:
    // await prefs.clear();

    initialized = true;
    notifyListeners();
  }

  /// Returns if the user's locaiton preference is known.
  bool? get locationPreferenceKnown {
    return _prefs?.getBool(locationPreferenceKnownKey) ?? false;
  }

  /// Returns if the user desires location access.
  bool? get locationAccessWanted {
    return _prefs?.getBool(locationAccessWantedKey);
  }
}
