import 'package:flutter/material.dart';

/// Holds the app's current [ThemeMode] and notifies listeners when it
/// changes, so MaterialApp can rebuild without depending on
/// ValueChangeObserver's cacheKey-scoped notifier lifecycle (which drops a
/// long-lived observer's registration when a short-lived sibling with the
/// same settings key disposes).
class ThemeModel extends ChangeNotifier {
  ThemeMode _mode;

  ThemeModel(this._mode);

  ThemeMode get mode => _mode;

  void setMode(ThemeMode mode) {
    _mode = mode;
    notifyListeners();
  }
}
