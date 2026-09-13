import 'package:flutter/material.dart';

class AccessoryIconModel {
  /// A list of all available icons
  static const List<String> icons = [
    "creditcard.fill", "briefcase.fill", "case.fill", "latch.2.case.fill",
    "key.fill", "mappin", "globe", "crown.fill",
    "gift.fill", "car.fill", "bicycle", "figure.walk",
    "heart.fill", "hare.fill", "tortoise.fill", "eye.fill",
  ];

  /// A mapping from the cupertino icon names to the material icon names.
  /// 
  /// If the icons do not match, so a similar replacement is used.
  static const iconMapping = {
    'creditcard.fill': Icons.credit_card,
    'briefcase.fill': Icons.business_center,
    'case.fill': Icons.work,
    // Was also Icons.business_center - pixel-identical to briefcase.fill
    // above, so two supposedly different picker options rendered as the
    // same glyph. luggage is visually distinct.
    'latch.2.case.fill': Icons.luggage,
    'key.fill': Icons.vpn_key,
    'mappin': Icons.place,
    // 'pushpin': Icons.push_pin,
    'globe': Icons.language,
    // Was Icons.school (a graduation cap) - workspace_premium is Material's
    // actual medal/premium-badge glyph, much closer to "crown".
    'crown.fill': Icons.workspace_premium,
    'gift.fill': Icons.redeem,
    'car.fill': Icons.directions_car,
    'bicycle': Icons.pedal_bike,
    'figure.walk': Icons.directions_walk,
    'heart.fill': Icons.favorite,
    // Was Icons.pets (a generic paw print) - cruelty_free is Material's
    // rabbit-face glyph, a direct match for "hare".
    'hare.fill': Icons.cruelty_free,
    // Was Icons.bug_report (a ladybug) - actively misleading, read as "bug"
    // rather than "tortoise". Material has no turtle glyph; shield is the
    // closest available nod (a tortoise's shell) rather than an unrelated
    // insect.
    'tortoise.fill': Icons.shield,
    'eye.fill': Icons.visibility,
  };

  /// Looks up the equivalent material icon for the cupertino icon [iconName].
  static IconData? mapIcon(String iconName) {
    return iconMapping[iconName];
  }
}
