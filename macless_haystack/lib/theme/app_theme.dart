import 'package:flutter/material.dart';

/// The app's light and dark [ThemeData], both seeded from the same brand
/// blue so Material 3 derives a coherent tonal palette (surfaces, buttons,
/// containers) instead of the single flat hue `primarySwatch` gives you.
///
/// Material 3 is on by default since Flutter 3.16, which silently stops
/// `ThemeData(primarySwatch: Colors.blue)` from feeding the real
/// `ColorScheme` - the app rendered purple instead of blue for exactly this
/// reason. `ColorScheme.fromSeed` is the actual Material 3 API for this.
abstract final class AppTheme {
  static const seedColor = Colors.blue;

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ),
      );
}
