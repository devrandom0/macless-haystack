import 'package:flutter/material.dart';
import 'package:macless_haystack/preferences/theme_model.dart';
import 'package:test/test.dart';

void main() {
  test('starts with the given initial mode', () {
    var model = ThemeModel(ThemeMode.dark);
    expect(model.mode, ThemeMode.dark);
  });

  test('setMode updates mode and notifies listeners', () {
    var model = ThemeModel(ThemeMode.system);
    var notified = false;
    model.addListener(() => notified = true);

    model.setMode(ThemeMode.light);

    expect(model.mode, ThemeMode.light);
    expect(notified, isTrue);
  });
}
