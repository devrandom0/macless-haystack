import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:intl/intl.dart';
import 'package:universal_io/io.dart';

import '../accessory/accessory_battery.dart';
import '../accessory/accessory_icon.dart';
import '../accessory/accessory_model.dart';
import '../util/place_format.dart';
import '../util/time_format.dart';

/// Height of the small triangular tail pointing from the card down at the
/// marker it belongs to.
const _tailHeight = 8.0;
const _tailWidth = 16.0;

/// Popup card shown next to a tapped accessory marker on the map, mirroring
/// [LocationPopup]'s Marker-subclass idiom from the history screen.
class AccessoryPopup extends Marker {
  /// Anchors the popup above the marker (the common case) when true, or
  /// below it when the caller has determined there isn't enough map height
  /// above the marker's screen position to fit the popup - without this, a
  /// marker tapped near the top of a short map viewport (e.g. a small map
  /// area, or a draggable sheet covering most of the screen) pushes the
  /// popup off-screen instead of showing it at all.
  AccessoryPopup({
    super.key,
    required Accessory accessory,
    required VoidCallback onNavigate,
    required VoidCallback onHistory,
    required VoidCallback onShare,
    bool showAbove = true,
    double maxHeight = 320,
    double horizontalAlignment = 0,
  }) : super(
          width: 250,
          height: maxHeight,
          point: accessory.lastLocation!,
          rotate: true,
          // The y component anchors the point to the marker's BOTTOM edge
          // instead of its center (topCenter), so the height extends upward
          // from the point rather than being centered on it (1, the
          // mirror image, extends downward for the flipped case). The 35px
          // pad then only needs to clear the 50px marker icon's near half
          // (25px) plus a 10px gap, and Align lets the content size to
          // itself within the remaining space instead of being stretched to
          // fill it - the tail is part of that content, so this same
          // padding places the tail's tip (not the card's edge) at the 10px
          // gap from the marker. The x component (usually 0, centered) lets
          // the caller shift the popup sideways to keep it on screen when
          // the marker sits near the map's left or right edge.
          alignment: Alignment(horizontalAlignment, showAbove ? -1 : 1),
          child: Padding(
            padding: showAbove
                ? const EdgeInsets.only(bottom: 35)
                : const EdgeInsets.only(top: 35),
            child: Align(
              alignment:
                  showAbove ? Alignment.bottomCenter : Alignment.topCenter,
              // Keyed by accessory id, not the enclosing Marker - flutter_map
              // repeats each Marker across every visible world copy at low
              // zoom, all as sibling Positioned widgets in one Stack, so a
              // key on the Marker itself becomes a duplicate-key crash on
              // any viewport wide enough to show more than one world. Keying
              // this inner subtree instead still remounts (and replays the
              // entrance animation) when the selected accessory changes,
              // without the Marker-level key that collides across worlds.
              child: _PopupContent(
                key: ValueKey(accessory.id),
                accessory: accessory,
                onNavigate: onNavigate,
                onHistory: onHistory,
                onShare: onShare,
                tailAbove: !showAbove,
                // 35 accounts for the tail + gap already carved out by the
                // padding above; without a cap here, a maxHeight tight
                // enough to trigger the flip in the first place would still
                // let the card render past the space the flip logic sized
                // it for.
                maxCardHeight: maxHeight - 35,
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

  /// Whether the tail points up at a marker above the card, instead of
  /// down at one below it.
  final bool tailAbove;

  /// Caps the card's height, falling back to a scrollable card instead of
  /// overflowing when the available map space is too tight for the card's
  /// natural size.
  final double? maxCardHeight;

  const _PopupContent({
    super.key,
    required this.accessory,
    required this.onNavigate,
    required this.onHistory,
    required this.onShare,
    this.tailAbove = false,
    this.maxCardHeight,
  });

  @override
  Widget build(BuildContext context) {
    var cardColor = Theme.of(context).colorScheme.surfaceContainerHigh;

    // Scales and fades in from the marker's point rather than just
    // appearing, so a brand-new selection reads as connected to the tap
    // that triggered it. Runs once per mount - this widget is keyed by
    // accessory id above, so switching to a different marker replays it,
    // but a live location update for the SAME selected accessory does not.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(
          scale: t,
          alignment: tailAbove ? Alignment.topCenter : Alignment.bottomCenter,
          child: child,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tailAbove)
            CustomPaint(
              size: const Size(_tailWidth, _tailHeight),
              painter: _TailPainter(color: cardColor, pointUp: true),
            ),
          InkWell(
            // Absorb taps so they don't fall through to the map and
            // dismiss the popup that was just opened.
            onTap: () {},
            child: Card(
              margin: EdgeInsets.zero,
              color: cardColor,
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxHeight: maxCardHeight ?? double.infinity),
                child: SingleChildScrollView(
                  child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Builder(builder: (context) {
                  var location = accessory.lastLocation!.round(decimals: 2);
                  var datePublished = accessory.datePublished;
                  var hasDate =
                      datePublished != null && datePublished != DateTime(1970);
                  const iconButtonConstraints =
                      BoxConstraints(minWidth: 48, minHeight: 48);
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
                      FutureBuilder<Placemark?>(
                        future: accessory.place,
                        builder: (context, snapshot) {
                          var locationText = formatPlacePair(
                                snapshot.data?.locality,
                                snapshot.data?.administrativeArea,
                              ) ??
                              'Lat: ${location.latitude}, Lng: ${location.longitude}';
                          return Text(
                            locationText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          );
                        },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            constraints: iconButtonConstraints,
                            padding: const EdgeInsets.all(8),
                            tooltip: 'Navigate',
                            icon: const Icon(Icons.directions),
                            color: Theme.of(context).colorScheme.primary,
                            onPressed: onNavigate,
                          ),
                          IconButton(
                            constraints: iconButtonConstraints,
                            padding: const EdgeInsets.all(8),
                            tooltip: 'History',
                            icon: const Icon(Icons.history),
                            color: Theme.of(context).colorScheme.primary,
                            onPressed: onHistory,
                          ),
                          IconButton(
                            constraints: iconButtonConstraints,
                            padding: const EdgeInsets.all(8),
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
          ),
          if (!tailAbove)
            CustomPaint(
              size: const Size(_tailWidth, _tailHeight),
              painter: _TailPainter(color: cardColor),
            ),
        ],
      ),
    );
  }
}

/// Draws a small triangle pointing at the marker the popup belongs to -
/// down when the card sits above the marker, up when it sits below.
class _TailPainter extends CustomPainter {
  final Color color;
  final bool pointUp;

  const _TailPainter({required this.color, this.pointUp = false});

  @override
  void paint(Canvas canvas, Size size) {
    var path = pointUp
        ? (Path()
          ..moveTo(0, size.height)
          ..lineTo(size.width, size.height)
          ..lineTo(size.width / 2, 0)
          ..close())
        : (Path()
          ..moveTo(0, 0)
          ..lineTo(size.width, 0)
          ..lineTo(size.width / 2, size.height)
          ..close());
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TailPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.pointUp != pointUp;
}
