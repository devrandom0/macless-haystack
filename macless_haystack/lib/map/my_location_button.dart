import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:provider/provider.dart';

/// A small floating button overlaid on the map that centers the camera on
/// the device's current location via [onLocationFound], requesting location
/// access first if it hasn't been granted (or fetched) yet.
class MyLocationButton extends StatelessWidget {
  final ValueChanged<LatLng> onLocationFound;

  const MyLocationButton({super.key, required this.onLocationFound});

  Future<void> _handleTap(BuildContext context) async {
    var locationModel = Provider.of<LocationModel>(context, listen: false);
    if (locationModel.here == null) {
      await locationModel.requestLocationUpdates();
    }
    var here = locationModel.here;
    if (here != null) {
      onLocationFound(here);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Location unavailable - check your device's location settings",
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 4,
      child: IconButton(
        tooltip: 'Move to my location',
        icon: Icon(
          Icons.my_location,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        onPressed: () => _handleTap(context),
      ),
    );
  }
}
