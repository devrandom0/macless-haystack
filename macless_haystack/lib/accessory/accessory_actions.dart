import 'package:flutter/material.dart';
import 'package:maps_launcher/maps_launcher.dart';
import 'package:share_plus/share_plus.dart';

import '../history/accessory_history.dart';
import 'accessory_model.dart';
import 'share_location.dart';

/// Opens the external maps app centered on [accessory]'s last known
/// location. Shared by the accessory list's swipe action and the map's
/// marker popup.
Future<void> navigateToAccessory(Accessory accessory) async {
  if (accessory.lastLocation == null || !accessory.isActive) {
    return;
  }
  var loc = accessory.lastLocation!;
  await MapsLauncher.launchCoordinates(loc.latitude, loc.longitude, accessory.name);
}

/// Pushes the location history screen for [accessory].
void openAccessoryHistory(BuildContext context, Accessory accessory) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (context) => AccessoryHistory(accessory: accessory)),
  );
}

/// Shares a maps link to [accessory]'s last known location via the native
/// share sheet.
void shareAccessoryLocation(Accessory accessory) {
  if (accessory.lastLocation == null || !accessory.isActive) {
    return;
  }
  var loc = accessory.lastLocation!;
  SharePlus.instance.share(
      ShareParams(text: buildLocationShareLink(loc.latitude, loc.longitude)));
}
