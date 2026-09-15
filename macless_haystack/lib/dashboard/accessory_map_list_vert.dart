import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_list.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/map/map.dart';
import 'package:macless_haystack/map/map_style_picker_button.dart';
import 'package:macless_haystack/map/my_location_button.dart';
import 'package:macless_haystack/notifications/notification_navigation.dart';
import 'package:latlong2/latlong.dart';

import '../callbacks.dart';

class AccessoryMapListVertical extends StatefulWidget {
  final LoadLocationUpdatesCallback loadLocationUpdates;
  final SaveOrderUpdatesCallback saveOrderUpdatesCallback;

  /// Displays a full-screen map with the accessory list in a draggable
  /// bottom sheet on top of it, instead of splitting the screen into two
  /// fixed halves.
  const AccessoryMapListVertical({
    super.key,
    required this.loadLocationUpdates,
    required this.saveOrderUpdatesCallback,
  });

  @override
  State<AccessoryMapListVertical> createState() =>
      _AccessoryMapListVerticalState();
}

class _AccessoryMapListVerticalState extends State<AccessoryMapListVertical> {
  final MapController _mapController = MapController();
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  // Fractions of the tab's available height. Peek keeps the list reachable
  // with a thumb while giving the map most of the screen; half is a
  // comfortable browsing size; full nearly covers the map for long lists.
  static const double _peekSize = 0.14;
  static const double _halfSize = 0.45;
  static const double _fullSize = 0.92;
  static const List<double> _snapSizes = [_peekSize, _halfSize, _fullSize];

  StreamSubscription<MapEvent>? _mapEventSubscription;

  @override
  void initState() {
    super.initState();
    // Collapse the sheet to peek height as soon as the user starts panning
    // or pinch-zooming, so dragging the map doesn't stay stuck under it -
    // gated to gesture starts (not every _mapController move) so this can't
    // fight with the pan/zoom itself or with a programmatic move like
    // _centerPoint's own fitCamera call.
    _mapEventSubscription = _mapController.mapEventStream.listen((event) {
      if (event.source == MapEventSource.dragStart ||
          event.source == MapEventSource.multiFingerGestureStart) {
        _collapseSheetToPeek(above: _peekSize);
      }
    });
    NotificationNavigation.pendingAccessoryId
        .addListener(_handlePendingNotificationAccessory);
  }

  /// Centers the map on the accessory a low-battery notification was
  /// tapped for, then clears the pending id - deferred to a post-frame
  /// callback since this can fire mid-build (the listener is registered in
  /// initState, and ValueNotifier calls listeners synchronously).
  void _handlePendingNotificationAccessory() {
    var accessoryId = NotificationNavigation.pendingAccessoryId.value;
    if (accessoryId == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      var registry = Provider.of<AccessoryRegistry>(context, listen: false);
      var location =
          resolveNotifiedAccessoryLocation(accessoryId, registry.accessories);
      if (location != null) {
        _centerPoint(location);
      }
      NotificationNavigation.pendingAccessoryId.value = null;
    });
  }

  /// Animates the sheet down to peek height, but only if it's currently
  /// expanded past [above].
  void _collapseSheetToPeek({required double above}) {
    if (_sheetController.isAttached && _sheetController.size > above) {
      _sheetController.animateTo(
        _peekSize,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _centerPoint(LatLng point) {
    // Pull the sheet back down to peek height first so the newly centered
    // marker isn't left hidden underneath it.
    _collapseSheetToPeek(above: _halfSize);
    _mapController.fitCamera(
      CameraFit.bounds(bounds: LatLngBounds.fromPoints([point])),
    );
  }

  @override
  void dispose() {
    _mapEventSubscription?.cancel();
    NotificationNavigation.pendingAccessoryId
        .removeListener(_handlePendingNotificationAccessory);
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AccessoryRegistry, LocationModel>(
      builder:
          (
            BuildContext context,
            AccessoryRegistry accessoryRegistry,
            LocationModel locationModel,
            Widget? child,
          ) {
            return Stack(
              children: [
                Positioned.fill(
                  child: AccessoryMap(mapController: _mapController),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: SafeArea(bottom: false, child: MapStylePickerButton()),
                ),
                Positioned(
                  top: 72,
                  right: 12,
                  child: SafeArea(
                    bottom: false,
                    child: MyLocationButton(onLocationFound: _centerPoint),
                  ),
                ),
                DraggableScrollableSheet(
                  controller: _sheetController,
                  initialChildSize: _halfSize,
                  minChildSize: _peekSize,
                  maxChildSize: _fullSize,
                  snap: true,
                  snapSizes: _snapSizes,
                  builder: (context, scrollController) {
                    return Material(
                      color: Theme.of(context).colorScheme.surface,
                      elevation: 8,
                      shadowColor: Colors.black45,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          const SizedBox(height: 10),
                          Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                // The Refresh FAB floats over this sheet at
                                // a fixed bottom-right screen position
                                // (Scaffold's default endFloat location,
                                // ~56 diameter + 16 margin), independent of
                                // the sheet's own size or scroll offset -
                                // without reserving space, a row (its
                                // trailing distance/time text in
                                // particular) landing in that corner
                                // renders unreadable underneath the button.
                                // But at the sheet's smallest (peek) size
                                // there's barely any height available at
                                // all - reserving a fixed amount there
                                // squeezed the list to zero height, which
                                // didn't just hide its content, it broke
                                // the sheet's own drag-to-resize gesture
                                // (nothing left to grab). Only reserve the
                                // clearance when there's comfortably enough
                                // room to spare it.
                                const fabClearance = 80.0;
                                const minContentHeight = 100.0;
                                var bottomPadding =
                                    constraints.maxHeight >=
                                            fabClearance + minContentHeight
                                        ? fabClearance
                                        : 0.0;
                                return Padding(
                                  padding: EdgeInsets.only(
                                    bottom: bottomPadding,
                                  ),
                                  child: AccessoryList(
                                    scrollController: scrollController,
                                    loadLocationUpdates:
                                        widget.loadLocationUpdates,
                                    saveOrderUpdatesCallback:
                                        widget.saveOrderUpdatesCallback,
                                    centerOnPoint: _centerPoint,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            );
          },
    );
  }
}
