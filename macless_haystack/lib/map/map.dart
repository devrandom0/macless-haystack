import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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
  String? _selectedAccessoryId;

  @override
  void initState() {
    super.initState();
    _mapController = widget.mapController ?? MapController();

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
  }

  void fitToContent(List<Accessory> accessories, LatLng? hereLocation) async {
    // Delay to prevent race conditions
    await Future.delayed(const Duration(milliseconds: 500));

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
    return Consumer2<AccessoryRegistry, LocationModel>(
      builder:
          (
            BuildContext context,
            AccessoryRegistry accessoryRegistry,
            LocationModel locationModel,
            Widget? child,
          ) {
            // Zoom map to fit all accessories on first accessory update only -
            // later rebuilds (e.g. from a device location update streaming in)
            // must not override a pan/zoom the user has already made.
            var accessories = accessoryRegistry.accessories;
            if (shouldFitToAccessoryLocations(
              accessories,
              _hasFittedToAccessories,
            )) {
              _hasFittedToAccessories = true;
              fitToContent(accessories, locationModel.here);
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

            var tileSource = mapTileSourceFromString(
              Settings.getValue<String>(
                mapTileProviderKey,
                defaultValue: mapTileProviderOsmValue,
              ),
            );

            return FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter:
                    locationModel.here ?? const LatLng(51.1657, 10.4515),
                maxZoom: 18.0,
                minZoom: 2.0,
                initialZoom: 13.0,
                backgroundColor: Theme.of(context).colorScheme.surface,
                interactionOptions: const InteractionOptions(
                  enableMultiFingerGestureRace: true,
                  flags:
                      InteractiveFlag.pinchZoom |
                      InteractiveFlag.drag |
                      InteractiveFlag.doubleTapZoom |
                      InteractiveFlag.scrollWheelZoom |
                      InteractiveFlag.flingAnimation |
                      InteractiveFlag.pinchMove |
                      InteractiveFlag.pinchZoom,
                ),
                onTap: (_, _) {
                  if (_selectedAccessoryId != null) {
                    setState(() => _selectedAccessoryId = null);
                  }
                },
              ),
              children: [
                TileLayer(
                  tileProvider: NetworkTileProvider(),
                  tileBuilder: (context, child, tile) {
                    var isDark =
                        (Theme.of(context).brightness == Brightness.dark) &&
                        !tileSource.isDark;
                    return isDark
                        ? ColorFiltered(
                            colorFilter: const ColorFilter.matrix([
                              -1,
                              0,
                              0,
                              0,
                              255,
                              0,
                              -1,
                              0,
                              0,
                              255,
                              0,
                              0,
                              -1,
                              0,
                              255,
                              0,
                              0,
                              0,
                              1,
                              0,
                            ]),
                            child: child,
                          )
                        : child;
                  },
                  urlTemplate: tileSource.urlTemplate,
                  subdomains: tileSource.subdomains,
                  userAgentPackageName: 'de.dchristl.headlesshaystack',
                ),
                MarkerLayer(
                  markers: [
                    ...accessories
                        .where((accessory) => accessory.isActive)
                        .where((accessory) => accessory.lastLocation != null)
                        .map(
                          (accessory) => Marker(
                            rotate: true,
                            width: 50,
                            height: 50,
                            point: accessory.lastLocation!,
                            child: Semantics(
                              button: true,
                              label: accessory.name,
                              child: GestureDetector(
                                // opaque so the marker's transparent surround
                                // (mostly empty space around the icon) is still
                                // tappable, and so the tap doesn't also fall
                                // through to MapOptions.onTap and dismiss the
                                // popup it just opened.
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  var isSelecting =
                                      _selectedAccessoryId != accessory.id;
                                  setState(() {
                                    _selectedAccessoryId = isSelecting
                                        ? accessory.id
                                        : null;
                                  });
                                  if (isSelecting) {
                                    _mapController.move(
                                      accessory.lastLocation!,
                                      _mapController.camera.zoom,
                                    );
                                  }
                                },
                                child: AccessoryIcon(
                                  icon: accessory.icon,
                                  color: accessory.color,
                                ),
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
                MarkerLayer(
                  markers: [
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
                  ],
                ),
                MarkerLayer(
                  markers: [
                    if (selected != null)
                      AccessoryPopup(
                        accessory: selected,
                        onNavigate: () => navigateToAccessory(selected),
                        onHistory: () =>
                            openAccessoryHistory(context, selected),
                        onShare: () => shareAccessoryLocation(selected),
                      ),
                  ],
                ),
                RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  attributions: [
                    TextSourceAttribution(tileSource.attributionText),
                  ],
                ),
              ],
            );
          },
    );
  }
}
