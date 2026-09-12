import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:universal_io/io.dart';

import '../accessory/accessory_battery.dart';
import '../accessory/accessory_icon.dart';
import '../accessory/accessory_model.dart';
import '../util/time_format.dart';

/// Height of the small triangular tail pointing from the card down at the
/// marker it belongs to.
const _tailHeight = 8.0;
const _tailWidth = 16.0;

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
          // alignment: topCenter anchors the point to the marker's BOTTOM
          // edge instead of its center, so the 400px height extends upward
          // from the point rather than being centered on it. The 35px bottom
          // pad then only needs to clear the 50px marker icon's top half
          // (25px above the point) plus a 10px gap, and Align(bottomCenter)
          // lets the content size to itself within the remaining space
          // instead of being stretched to fill it - the tail is part of
          // that content, so this same padding places the tail's tip (not
          // the card's bottom edge) at the 10px gap above the marker.
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 35),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: _PopupContent(
                accessory: accessory,
                onNavigate: onNavigate,
                onHistory: onHistory,
                onShare: onShare,
              ),
            ),
          ),
        );
}

class _PopupContent extends StatelessWidget {
  final Accessory accessory;
  final VoidCallback onNavigate;
  final VoidCallback onHistory;
  final VoidCallback onShare;

  const _PopupContent({
    required this.accessory,
    required this.onNavigate,
    required this.onHistory,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    var cardColor = Theme.of(context).colorScheme.surfaceContainerHigh;

    // Scales and fades in from the marker's point rather than just
    // appearing, so a brand-new selection reads as connected to the tap
    // that triggered it. Runs once per mount - map.dart keys this widget
    // by accessory id, so switching to a different marker replays it, but
    // a live location update for the SAME selected accessory does not.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(
          scale: t,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            // Absorb taps so they don't fall through to the map and
            // dismiss the popup that was just opened.
            onTap: () {},
            child: Card(
              margin: EdgeInsets.zero,
              color: cardColor,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Builder(builder: (context) {
                  var location = accessory.lastLocation!.round(decimals: 2);
                  var datePublished = accessory.datePublished;
                  var hasDate =
                      datePublished != null && datePublished != DateTime(1970);
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
                        maxLines: 2,
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
          CustomPaint(
            size: const Size(_tailWidth, _tailHeight),
            painter: _TailPainter(color: cardColor),
          ),
        ],
      ),
    );
  }
}

/// Draws a small downward-pointing triangle, giving the popup a visible
/// anchor to the marker it belongs to instead of floating unexplained.
class _TailPainter extends CustomPainter {
  final Color color;

  const _TailPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    var path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TailPainter oldDelegate) => oldDelegate.color != color;
}
