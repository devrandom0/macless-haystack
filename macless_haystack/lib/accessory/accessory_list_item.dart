
import 'dart:async';

import 'package:universal_io/io.dart';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:macless_haystack/accessory/accessory_icon.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
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
          locationString = '${place.locality}, ${place.administrativeArea}';
          if (widget.herePlace != null &&
              widget.herePlace!.country != place.country) {
            locationString = '${place.locality}, ${place.country}';
          }
        }
        // Format published date in a human readable way
        String? dateString = widget.accessory.datePublished != null &&
                widget.accessory.datePublished != DateTime(1970)
            ? '\n${DateFormat.yMMMd(Platform.localeName).format(widget.accessory.datePublished!)} ${formatTime(widget.accessory.datePublished!)}'
            : '';

        return AnimatedContainer(
            duration: const Duration(milliseconds: 300), // Sanfter Übergang
            color: _tileColor,
            child: ListTile(
              onTap: widget.onTap,
              title: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.accessory.name,
                    style: TextStyle(
                      fontSize: 14,
                      color: widget.accessory.isActive
                          ? Theme.of(context).colorScheme.onSurface
                          : Theme.of(context).disabledColor,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _buildIcon(),
                ],
              ),
              subtitle: Text(
                locationString + dateString,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: widget.distance,
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
}
