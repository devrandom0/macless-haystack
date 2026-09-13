import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_list.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/map/map.dart';
import 'package:macless_haystack/map/map_style_picker_button.dart';
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

  void _centerPoint(LatLng point) {
    // Pull the sheet back down to peek height first so the newly centered
    // marker isn't left hidden underneath it.
    if (_sheetController.isAttached && _sheetController.size > _halfSize) {
      _sheetController.animateTo(
        _peekSize,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    _mapController.fitCamera(
      CameraFit.bounds(bounds: LatLngBounds.fromPoints([point])),
    );
  }

  @override
  void dispose() {
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
                            child: AccessoryList(
                              scrollController: scrollController,
                              loadLocationUpdates: widget.loadLocationUpdates,
                              saveOrderUpdatesCallback:
                                  widget.saveOrderUpdatesCallback,
                              centerOnPoint: _centerPoint,
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
