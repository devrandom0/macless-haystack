import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_actions.dart';
import 'package:macless_haystack/accessory/accessory_icon.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/map/accessory_popup.dart';
import 'package:macless_haystack/map/map_tile_source.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
import 'package:provider/provider.dart';

/// Whether the map should auto-fit its camera to [accessories]' current
/// locations. This is only desired once - the first time a location becomes
/// available - so a later, unrelated rebuild (e.g. a device location update
/// streaming in) doesn't override a pan/zoom the user has already made.
bool shouldFitToAccessoryLocations(
  List<Accessory> accessories,
  bool hasFittedToAccessories,
) {
  if (hasFittedToAccessories) {
    return false;
  }
  return accessories.any(
    (accessory) => accessory.isActive && accessory.lastLocation != null,
  );
}

/// The accessory with id [selectedId], restricted to one that is still
/// active with a known location. The registry streams updates and hands out
/// new/cloned instances, so holding an id (not the accessory itself) and
/// resolving it fresh on every build keeps the popup following live
/// location updates, and makes it disappear on its own once the accessory
/// is deactivated or its location is cleared, instead of lingering stale.
Accessory? selectedAccessory(List<Accessory> accessories, String? selectedId) {
  if (selectedId == null) {
    return null;
  }
  for (var accessory in accessories) {
    if (accessory.id == selectedId) {
      return accessory.isActive && accessory.lastLocation != null
          ? accessory
          : null;
    }
  }
  return null;
}

/// Whether [mergedMarkers] - markers flutter_map_marker_cluster just grouped
/// into a cluster on zoom-out - includes the currently selected accessory
/// (identified by [selectedId] via each marker's ValueKey). A popup anchored
/// to a count badge instead of the real marker wouldn't make sense, so the
/// popup should close when this is true.
bool clusterAbsorbedSelection(List<Marker> mergedMarkers, String? selectedId) {
  if (selectedId == null) {
    return false;
  }
  return mergedMarkers.any((marker) => marker.key == ValueKey(selectedId));
}

/// The accessory in [accessories] whose id matches [marker]'s key, or null
/// if not found. Markers are only ever built from this same accessories
/// list, so this should always find a match in practice - the null case is
/// defensive, since tap callbacks can in principle fire after the list has
/// changed out from under them.
Accessory? accessoryForMarker(List<Accessory> accessories, Marker marker) {
  var key = marker.key;
  if (key is! ValueKey<String>) {
    return null;
  }
  for (var accessory in accessories) {
    if (accessory.id == key.value) {
      return accessory;
    }
  }
  return null;
}

/// Where and how large to render the accessory popup, given the selected
/// marker's [markerScreenPoint] and the map's [viewportSize]. Keeps the
/// fixed-width/height popup within [margin] of the viewport's edges
/// whenever the marker's position allows it: flips above/below depending on
/// which side has more room, and only shrinks the popup below
/// [desiredHeight] when neither side has enough room at all.
class PopupPlacement {
  final bool showAbove;
  final double maxHeight;
  final double horizontalAlignment;

  const PopupPlacement({
    required this.showAbove,
    required this.maxHeight,
    required this.horizontalAlignment,
  });
}

PopupPlacement popupPlacementFor({
  required Offset markerScreenPoint,
  required Size viewportSize,
  double popupWidth = 250.0,
  double desiredHeight = 320.0,
  double margin = 16.0,
  double minHeight = 120.0,
}) {
  var screenY = markerScreenPoint.dy;
  var spaceAbove = screenY - margin;
  var spaceBelow = viewportSize.height - screenY - margin;
  bool showAbove;
  double maxHeight;
  if (spaceAbove >= desiredHeight) {
    showAbove = true;
    maxHeight = desiredHeight;
  } else if (spaceBelow >= desiredHeight) {
    showAbove = false;
    maxHeight = desiredHeight;
  } else if (spaceAbove >= spaceBelow) {
    showAbove = true;
    maxHeight = spaceAbove.clamp(minHeight, desiredHeight);
  } else {
    showAbove = false;
    maxHeight = spaceBelow.clamp(minHeight, desiredHeight);
  }

  var screenX = markerScreenPoint.dx;
  var desiredLeft = screenX - popupWidth / 2;
  var maxLeft = viewportSize.width - margin - popupWidth;
  // A viewport narrower than the popup plus its margins can't fit either
  // constraint - fall back to the left margin rather than let clamp() throw
  // on a lower bound greater than its upper bound.
  var clampedLeft =
      maxLeft < margin ? margin : desiredLeft.clamp(margin, maxLeft);
  // flutter_map positions a Marker's box as
  // [point - 0.5*W*(1-a), point + 0.5*W*(1+a)] - alignment.x=-1 puts the
  // box's RIGHT edge at the point (box extends left), +1 puts the LEFT
  // edge at the point (box extends right). Solving for the desired left
  // edge gives this, not the mirrored version.
  var horizontalAlignment =
      (1 - 2 * (screenX - clampedLeft) / popupWidth).clamp(-1.0, 1.0);

  return PopupPlacement(
    showAbove: showAbove,
    maxHeight: maxHeight,
    horizontalAlignment: horizontalAlignment,
  );
}

class AccessoryMap extends StatefulWidget {
  final MapController? mapController;

  /// Displays a map with all accessories at their latest position.
  const AccessoryMap({super.key, this.mapController});

  @override
  State<StatefulWidget> createState() {
    return _AccessoryMapState();
  }
}

class _AccessoryMapState extends State<AccessoryMap> {
  late MapController _mapController;
  void Function()? cancelLocationUpdates;
  void Function()? cancelAccessoryUpdates;
  bool _hasFittedToAccessories = false;
  // The controller can't move/fit the camera until FlutterMap has actually
  // mounted - onMapReady is the real signal for that, not a guessed delay.
  bool _mapReady = false;
  String? _selectedAccessoryId;
  StreamSubscription<MapEvent>? _mapEventSubscription;

  @override
  void initState() {
    super.initState();
    _mapController = widget.mapController ?? MapController();

    // The popup's on-screen position/size is computed at build time from
    // the marker's current screen offset, but pure camera pan/zoom (with no
    // Provider change) never triggers a rebuild on its own - without this,
    // panning while a popup is open leaves it anchored at whatever
    // alignment was computed when it was selected, so it drifts off screen
    // instead of staying clamped as the marker moves toward an edge.
    _mapEventSubscription = _mapController.mapEventStream.listen((event) {
      if (mounted && _selectedAccessoryId != null) {
        setState(() {});
      }
    });

    var accessoryRegistry = Provider.of<AccessoryRegistry>(
      context,
      listen: false,
    );
    var locationModel = Provider.of<LocationModel>(context, listen: false);

    // Resize map to fit all accessories at initial location
    _hasFittedToAccessories = shouldFitToAccessoryLocations(
      accessoryRegistry.accessories,
      false,
    );
    fitToContent(accessoryRegistry.accessories, locationModel.here);

    // Fit map if first location is known
    void listener() {
      // Only use the first location, cancel further updates
      cancelLocationUpdates?.call();
      fitToContent(accessoryRegistry.accessories, locationModel.here);
    }

    locationModel.addListener(listener);
    cancelLocationUpdates = () => locationModel.removeListener(listener);

    // Fit map if accessories change?
  }

  @override
  void dispose() {
    super.dispose();

    cancelLocationUpdates?.call();
    cancelAccessoryUpdates?.call();
    _mapEventSubscription?.cancel();
  }

  void fitToContent(List<Accessory> accessories, LatLng? hereLocation) {
    // The camera can't move before FlutterMap has actually mounted and
    // attached to this controller. onMapReady re-invokes this once that
    // happens, so an early call here (e.g. from initState) can just skip
    // itself rather than guess how long mounting takes.
    if (!_mapReady) {
      return;
    }

    List<LatLng> points = [];
    if (hereLocation != null) {
      _mapController
        ..move(hereLocation, _mapController.camera.zoom)
        ..move(
          _mapController.camera.center,
          _mapController.camera.zoom + 0.00001,
        );
      points = [hereLocation];
    }

    List<LatLng> accessoryPoints = accessories
        .where((accessory) => accessory.isActive)
        .where((accessory) => accessory.lastLocation != null)
        .map((accessory) => accessory.lastLocation!)
        .toList();
    if (accessoryPoints.isNotEmpty) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([...points, ...accessoryPoints]),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AccessoryRegistry, LocationModel>(builder:
        (BuildContext context, AccessoryRegistry accessoryRegistry,
            LocationModel locationModel, Widget? child) {
      // Zoom map to fit all accessories on first accessory update only -
      // later rebuilds (e.g. from a device location update streaming in)
      // must not override a pan/zoom the user has already made.
      var accessories = accessoryRegistry.accessories;
      if (shouldFitToAccessoryLocations(accessories, _hasFittedToAccessories)) {
        _hasFittedToAccessories = true;
        // fitToContent moves the map controller, which must not happen
        // while this very build is still in progress - deferred the same
        // way the selected-accessory reset below already is.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            fitToContent(accessories, locationModel.here);
          }
        });
      }
      var selected = selectedAccessory(accessories, _selectedAccessoryId);
      if (_selectedAccessoryId != null && selected == null) {
        // The accessory was deactivated or lost its location, so its id
        // must be cleared too - otherwise the popup would silently
        // reappear if that same accessory becomes selectable again later.
        // setState can't run mid-build, so defer it to after this frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() => _selectedAccessoryId = null);
          }
        });
      }

      // ValueChangeObserver (rather than a plain Settings.getValue read) so
      // this rebuilds live when the on-map style picker changes the
      // setting, without needing a pop/navigate back to this screen to
      // pick up the new value.
      return ValueChangeObserver<String>(
        cacheKey: mapTileProviderKey,
        defaultValue: mapTileProviderOsmValue,
        builder: (context, tileProviderValue, onTileProviderChanged) {
          var tileSource = mapTileSourceFromString(tileProviderValue);
          return _buildMap(
              context, accessories, locationModel, selected, tileSource);
        },
      );
    });
  }

  Widget _buildMap(
    BuildContext context,
    List<Accessory> accessories,
    LocationModel locationModel,
    Accessory? selected,
    MapTileSource tileSource,
  ) {
    return LayoutBuilder(builder: (context, constraints) {
      // Where/how large to render the popup - without this, a marker
      // tapped near an edge of a short or narrow map viewport (e.g. a
      // small map area, or a draggable sheet covering most of the screen)
      // pushed the fixed-size popup off-screen instead of showing it.
      // camera is only valid once _mapReady, which is guaranteed by the
      // time selected is non-null (a marker can't be tapped before
      // FlutterMap has rendered).
      var showPopupAbove = true;
      var popupMaxHeight = 320.0;
      var popupHorizontalAlignment = 0.0;
      if (selected != null && _mapReady) {
        var placement = popupPlacementFor(
          markerScreenPoint: _mapController.camera
              .latLngToScreenOffset(selected.lastLocation!),
          viewportSize: constraints.biggest,
        );
        showPopupAbove = placement.showAbove;
        popupMaxHeight = placement.maxHeight;
        popupHorizontalAlignment = placement.horizontalAlignment;
      }

      return FlutterMap(
        mapController: _mapController,
        options: MapOptions(
            initialCenter: locationModel.here ?? const LatLng(51.1657, 10.4515),
            maxZoom: 18.0,
            minZoom: 2.0,
            initialZoom: 13.0,
            backgroundColor: Theme.of(context).colorScheme.surface,
            interactionOptions: const InteractionOptions(
                enableMultiFingerGestureRace: true,
                flags: InteractiveFlag.pinchZoom |
                    InteractiveFlag.drag |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.scrollWheelZoom |
                    InteractiveFlag.flingAnimation |
                    InteractiveFlag.pinchMove |
                    InteractiveFlag.pinchZoom),
            onMapReady: () {
              _mapReady = true;
              fitToContent(accessories, locationModel.here);
            },
            onTap: (_, _) {
              if (_selectedAccessoryId != null) {
                setState(() => _selectedAccessoryId = null);
              }
            }),
        children: [
          TileLayer(
            tileProvider: NetworkTileProvider(),
            // A plain RGB invert is a photographic negative: it flips
            // hue as well as luminance, so amber roads turn blue and
            // green parks turn magenta. flutter_map's own
            // darkModeTileBuilder composes the invert with a 180-degree
            // hue rotation, which restores the original hues at the
            // flipped luminance instead. Skipped entirely for a tile
            // source that's already dark on its own.
            tileBuilder: Theme.of(context).brightness == Brightness.dark &&
                    !tileSource.isDark
                ? darkModeTileBuilder
                : null,
            urlTemplate: tileSource.urlTemplate,
            subdomains: tileSource.subdomains,
            userAgentPackageName: 'de.dchristl.headlesshaystack',
          ),
          MarkerClusterLayerWidget(
            options: MarkerClusterLayerOptions(
              maxClusterRadius: 45,
              size: const Size(44, 44),
              // Zoom-to-bounds-on-cluster-tap can't help once already at
              // the map's own max zoom (18, see MapOptions below) - without
              // this, two accessories close enough to share a cluster at
              // that zoom would have no way to ever be shown/tapped
              // individually. One zoom level of margin below the map's max.
              // Zoom-to-bounds-on-cluster-tap can't help once already at the
              // map's own max zoom (18, see MapOptions below) - without
              // this, two accessories close enough to share a cluster at
              // that zoom would have no way to ever be shown/tapped
              // individually. Markers within roughly 20m of each other can
              // still land in the same cluster right at this boundary
              // (observed on-device, not fully root-caused - flutter_map_
              // marker_cluster hasn't had a release in ~11 months and this
              // may be a library-side edge case) - tapping such a cluster
              // still zooms in as far as it can, it just doesn't guarantee
              // full separation for pathologically close pairs.
              disableClusteringAtZoom: 15,
              markers: accessories
                  .where((accessory) => accessory.isActive)
                  .where((accessory) => accessory.lastLocation != null)
                  .map((accessory) => Marker(
                        key: ValueKey(accessory.id),
                        rotate: true,
                        width: 50,
                        height: 50,
                        point: accessory.lastLocation!,
                        child: Semantics(
                          button: true,
                          label: accessory.name,
                          child: AccessoryIcon(
                              icon: accessory.icon, color: accessory.color),
                        ),
                      ))
                  .toList(),
              // Centering is handled by hand below, only when actually
              // selecting (not deselecting) - the package's own
              // centerMarkerOnClick would recenter on every tap including a
              // deselect, which this app's existing tap behavior never did.
              centerMarkerOnClick: false,
              onMarkerTap: (marker) {
                var accessory = accessoryForMarker(accessories, marker);
                if (accessory == null) {
                  return;
                }
                var isSelecting = _selectedAccessoryId != accessory.id;
                setState(() {
                  _selectedAccessoryId = isSelecting ? accessory.id : null;
                });
                if (isSelecting) {
                  _mapController.move(
                      accessory.lastLocation!, _mapController.camera.zoom);
                }
              },
              // Fires when zooming out merges markers into a cluster - if
              // the selected accessory is one of them, its popup would be
              // left pointing at a count badge instead of the real marker.
              onMarkersClustered: (mergedMarkers) {
                if (clusterAbsorbedSelection(
                    mergedMarkers, _selectedAccessoryId)) {
                  setState(() => _selectedAccessoryId = null);
                }
              },
              builder: (context, markers) {
                return Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${markers.length}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              },
            ),
          ),
          MarkerLayer(markers: [
            if (locationModel.here != null)
              Marker(
                width: 25.0,
                height: 25.0,
                point: locationModel.here!,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(5),
                      child: Container(
                        decoration: BoxDecoration(
                          // indicatorColor resolves to onPrimarySurfaceColor,
                          // which is white in the light theme and invisible
                          // against the surface-colored circle behind it.
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ]),
          MarkerLayer(markers: [
            if (selected != null)
              AccessoryPopup(
                accessory: selected,
                onNavigate: () => navigateToAccessory(selected),
                onHistory: () => openAccessoryHistory(context, selected),
                onShare: () => shareAccessoryLocation(selected),
                showAbove: showPopupAbove,
                maxHeight: popupMaxHeight,
                horizontalAlignment: popupHorizontalAlignment,
              ),
          ]),
          RichAttributionWidget(
            alignment: AttributionAlignment.bottomLeft,
            attributions: [
              TextSourceAttribution(tileSource.attributionText),
            ],
          ),
        ],
      );
    });
  }
}
