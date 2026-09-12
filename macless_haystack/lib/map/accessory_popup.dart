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
          height: 400,
          point: accessory.lastLocation!,
          rotate: true,
          // The 50px marker's top half reaches 25px above the point, so the
          // bottom pad needs to clear that plus a gap, leaving the rest of
          // the height for the card to grow into at larger accessibility
          // text scales without overflowing.
          child: Padding(
            padding: const EdgeInsets.only(bottom: 235),
            child: InkWell(
              // Absorb taps so they don't fall through to the map and
              // dismiss the popup that was just opened.
              onTap: () {},
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  child: Builder(builder: (context) {
                    var location =
                        accessory.lastLocation!.round(decimals: 2);
                    var datePublished = accessory.datePublished;
                    var hasDate = datePublished != null &&
                        datePublished != DateTime(1970);
                    const compactIconConstraints =
                        BoxConstraints(minWidth: 32, minHeight: 32);
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Text(
                          'Lat: ${location.latitude}, Lng: ${location.longitude}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              constraints: compactIconConstraints,
                              padding: EdgeInsets.zero,
                              tooltip: 'Navigate',
                              icon: const Icon(Icons.directions),
                              color: Theme.of(context).colorScheme.primary,
                              onPressed: onNavigate,
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              constraints: compactIconConstraints,
                              padding: EdgeInsets.zero,
                              tooltip: 'History',
                              icon: const Icon(Icons.history),
                              color: Theme.of(context).colorScheme.primary,
                              onPressed: onHistory,
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              constraints: compactIconConstraints,
                              padding: EdgeInsets.zero,
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
          ),
        );
}
