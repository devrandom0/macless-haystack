import 'dart:async';

import 'package:universal_io/io.dart';

import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:geocoding/geocoding.dart';
import 'package:macless_haystack/accessory/accessory_icon.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
import 'package:macless_haystack/util/place_format.dart';
import 'package:macless_haystack/util/time_format.dart';
import 'package:intl/intl.dart';

import 'accessory_battery.dart';

class AccessoryListItem extends StatefulWidget {
  final Accessory accessory;
  final Widget? distance;
  final Placemark? herePlace;
  final VoidCallback onTap;

  const AccessoryListItem({
    super.key,
    required this.accessory,
    required this.onTap,
    this.distance,
    this.herePlace,
  });

  @override
  AccessoryListItemState createState() => AccessoryListItemState();
}

class AccessoryListItemState extends State<AccessoryListItem> {
  Color _tileColor = Colors.transparent;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _updateHighlight();
  }

  @override
  void didUpdateWidget(covariant AccessoryListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateHighlight();
  }

  void _updateHighlight() {
    if (widget.accessory.hasChangedFlag && _highlightTimer == null) {
      _tileColor = widget.accessory.color.withAlpha(50);
      _highlightTimer = Timer(const Duration(seconds: 1), () {
        _highlightTimer = null;
        if (mounted) {
          widget.accessory.hasChangedFlag = false;
          setState(() {
            _tileColor = Colors.transparent;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Placemark?>(
      future: widget.accessory.place,
      builder: (BuildContext context, AsyncSnapshot<Placemark?> snapshot) {
        String locationString = widget.accessory.lastLocation != null
            ? '${widget.accessory.lastLocation!.latitude.toStringAsFixed(4)}, ${widget.accessory.lastLocation!.longitude.toStringAsFixed(4)}'
            : 'Unknown';

        if (snapshot.hasData && snapshot.data != null) {
          Placemark place = snapshot.data!;
          var pair = widget.herePlace != null &&
                  widget.herePlace!.country != place.country
              ? formatPlacePair(place.locality, place.country)
              : formatPlacePair(place.locality, place.administrativeArea);
          if (pair != null) {
            locationString = pair;
          }
        }
        // Format published date in a human readable way
        String? dateString =
            widget.accessory.datePublished != null &&
                widget.accessory.datePublished != DateTime(1970)
            ? '\n${DateFormat.yMMMd(Platform.localeName).format(widget.accessory.datePublished!)} ${formatTime(widget.accessory.datePublished!)}'
            : '';

        var isCompact =
            Settings.getValue<bool>(
              compactAccessoryListKey,
              defaultValue: true,
            ) ??
            true;

        return AnimatedContainer(
            duration: const Duration(milliseconds: 300), // Sanfter Übergang
            color: _tileColor,
            child: ListTile(
              onTap: widget.onTap,
              title: isCompact
                  ? _buildCompactTitle(context)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.accessory.name,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: widget.accessory.isActive
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Theme.of(context).disabledColor,
                              ),
                        ),
                        const SizedBox(width: 4),
                        _buildIcon(),
                      ],
                    ),
              subtitle: isCompact
                  ? null
                  : Text(
                      locationString + dateString,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
              trailing: isCompact ? _buildCompactTrailing(context) : widget.distance,
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              minVerticalPadding: 0,
              leading: AccessoryIcon(
                icon: widget.accessory.icon,
                color: widget.accessory.color,
                size: 20,
              ),
            ));
      },
    );
  }

  Widget _buildIcon() {
    return AccessoryBatteryIcon(status: widget.accessory.lastBatteryStatus);
  }

  Widget _buildCompactTitle(BuildContext context) {
    return Text(
      widget.accessory.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: widget.accessory.isActive
                ? Theme.of(context).colorScheme.onSurface
                : Theme.of(context).disabledColor,
          ),
    );
  }

  Widget _buildCompactTrailing(BuildContext context) {
    var datePublished = widget.accessory.datePublished;
    String? lastSeen = datePublished != null && datePublished != DateTime(1970)
        ? formatRelativeTime(
            datePublished,
            DateTime.now(),
            locale: Platform.localeName,
          )
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.distance != null) widget.distance!,
        if (widget.distance != null && lastSeen != null)
          const SizedBox(width: 6),
        if (lastSeen != null)
          Text(
            lastSeen,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
      ],
    );
  }
}
