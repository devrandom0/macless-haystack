import 'package:flutter/foundation.dart';

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
class MapTileProviderModel extends ChangeNotifier {
  String _value;

  MapTileProviderModel(this._value);

  String get value => _value;

  void setValue(String value) {
    if (_value == value) return;
    _value = value;
    notifyListeners();
  }
}
