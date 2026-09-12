import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:universal_io/io.dart';

import '../accessory/accessory_battery.dart';
import '../accessory/accessory_icon.dart';
import '../accessory/accessory_model.dart';
import '../util/time_format.dart';

/// Popup card shown above a tapped accessory marker on the map, mirroring
/// [LocationPopup]'s Marker-subclass idiom from the history screen.
class AccessoryPopup extends Marker {
  AccessoryPopup({
    super.key,
    required Accessory accessory,
    required VoidCallback onNavigate,
    required VoidCallback onHistory,
    required VoidCallback onShare,
  }) : super(
          width: 250,
          height: 190,
          point: accessory.lastLocation!,
          rotate: true,
          // A 55px bottom pad clears the 50px marker's 25px top half with
          // ~30px to spare, so the card floats above the point instead of
          // covering it.
          child: Padding(
            padding: const EdgeInsets.only(bottom: 55),
            child: Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Builder(builder: (context) {
                  var location = accessory.lastLocation!.round(decimals: 2);
                  var datePublished = accessory.datePublished;
                  var hasDate = datePublished != null &&
                      datePublished != DateTime(1970);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          AccessoryIcon(
                            icon: accessory.icon,
                            color: accessory.color,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              accessory.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (accessory.lastBatteryStatus != null)
                            AccessoryBatteryIcon(
                              status: accessory.lastBatteryStatus,
                              size: 15,
                            ),
                        ],
                      ),
                      if (hasDate)
                        Text(
                          '${DateFormat.yMMMd(Platform.localeName).format(datePublished)} '
                          '${formatTime(datePublished)}',
                        ),
                      Text(
                        'Lat: ${location.latitude}, Lng: ${location.longitude}',
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Navigate',
                            icon: const Icon(Icons.directions),
                            color: Theme.of(context).colorScheme.primary,
                            onPressed: onNavigate,
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'History',
                            icon: const Icon(Icons.history),
                            color: Theme.of(context).colorScheme.primary,
                            onPressed: onHistory,
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Share',
                            icon: const Icon(Icons.share),
                            color: Theme.of(context).colorScheme.primary,
                            onPressed: onShare,
                          ),
                        ],
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
        );
}
