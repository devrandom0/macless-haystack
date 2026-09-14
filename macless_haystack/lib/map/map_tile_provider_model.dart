import 'package:flutter/foundation.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

/// Holds the app's current map tile provider setting and notifies listeners
/// when it changes, so the map screen and its on-map style picker can react
/// live without depending on flutter_settings_screens' ValueChangeObserver -
/// its cacheKey-scoped notifier list is shared across every concurrently
/// mounted observer for that key, and its dispose() clears the whole list
/// for the key, not just its own entry. Once the Settings page's dropdown
/// (a short-lived observer for this same key) was visited and closed, it
/// wiped out the map's own (long-lived) registration too, so picking a new
/// style there stopped reaching the map. See ThemeModel for the same fix
/// applied to theme mode.
///
/// setValue persists to Settings itself (rather than relying on a caller's
/// own DropDownSettingsTile to do it) - the on-map picker has no such tile
/// backing it, so without this its selection would only live in memory and
/// be lost the next time the app starts.
class MapTileProviderModel extends ChangeNotifier {
  String _value;
  String _cartoApiKey;

  MapTileProviderModel(this._value, this._cartoApiKey);

  String get value => _value;

  String get cartoApiKey => _cartoApiKey;

  void setValue(String value) {
    if (_value == value) return;
    _value = value;
    Settings.setValue<String>(mapTileProviderKey, value);
    notifyListeners();
  }

  void setCartoApiKey(String cartoApiKey) {
    if (_cartoApiKey == cartoApiKey) return;
    _cartoApiKey = cartoApiKey;
    Settings.setValue<String>(cartoApiKeyKey, cartoApiKey);
    notifyListeners();
  }
}
