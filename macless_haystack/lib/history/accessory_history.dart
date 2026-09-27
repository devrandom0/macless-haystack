import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:logger/logger.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/history/days_selection_slider.dart';
import 'package:macless_haystack/history/gpx_export.dart';
import 'package:macless_haystack/history/location_popup.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
import 'package:macless_haystack/refresh_coordinator.dart';
import 'package:macless_haystack/widgets/refresh_icon_button.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:universal_html/html.dart' as html;

import 'dart:math';

class AccessoryHistory extends StatefulWidget {
  final Accessory accessory;
  final RefreshCoordinator refreshCoordinator;

  /// Shows previous locations of a specific [accessory] on a map.
  /// The locations are connected by a chronological line.
  /// The number of days to go back can be adjusted with a slider.
  const AccessoryHistory({
    super.key,
    required this.accessory,
    required this.refreshCoordinator,
  });

  @override
  State<StatefulWidget> createState() {
    return _AccessoryHistoryState();
  }
}

class _AccessoryHistoryState extends State<AccessoryHistory> {
  late MapController _mapController;

  bool showPopup = false;
  Pair<dynamic, dynamic>? popupEntry;

  int numberOfDays = 7;
  bool isLineLayerVisible = true;
  bool isPointLayerVisible = true;
  late int _maxDays;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();

    // The slider can't usefully go back further than however many days the
    // app actually fetches from the endpoint - beyond that there's no data
    // to show regardless of where the slider is set.
    _maxDays =
        Settings.getValue<int>(numberOfDaysToFetch, defaultValue: 7) ?? 7;
    if (_maxDays < 1) {
      _maxDays = 1;
    }
    numberOfDays = min(numberOfDays, _maxDays);

    DateTime latest = widget.accessory.latestHistoryEntry();
    numberOfDays =
        min(DateTime.now().difference(latest).inDays + 1, numberOfDays);
  }

  @override
  Widget build(BuildContext context) {
    // filteredEntries and everything derived from it must be recomputed
    // inside the builder below, not out here - only the builder re-runs
    // when the coordinator notifies (this outer build() does not), and
    // widget.accessory.locationHistory is exactly what a refresh updates.
    return ValueListenableBuilder<Set<String>>(
      valueListenable: widget.refreshCoordinator,
      builder: (context, refreshingIds, child) {
        List<Pair<dynamic, dynamic>> filteredEntries = filterHistoryEntries();
        var historyLength = filteredEntries.length;
        List<Polyline> polylines = [];

        if (historyLength > 255) {
          historyLength = 255;
        }
        int delta = (255 ~/ max(1, (historyLength - 1))).ceil();
        var blue = delta;

        for (int i = 0; i < filteredEntries.length - 1; i++) {
          var entry = filteredEntries[i];
          var nextEntry = filteredEntries[i + 1];
          List<LatLng> points = [];
          points.add(entry.location);
          points.add(nextEntry.location);

          if (isLineLayerVisible) {
            polylines.add(Polyline(
              points: points,
              strokeWidth: 4,
              color: Color.fromRGBO(33, 150, blue, 1),
            ));
          }
          blue += min(delta.toInt(), 255);
        }
        // Filter for the locations after the specified cutoff date (now - number of days)
        var visibility = [isLineLayerVisible, isPointLayerVisible];
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.accessory.name, overflow: TextOverflow.ellipsis),
            actions: [
              RefreshIconButton(
                refreshing: refreshingIds.contains(widget.accessory.id),
                onPressed: widget.accessory.isActive ? _refresh : null,
              ),
              IconButton(
                tooltip: 'Export history',
                onPressed:
                    filteredEntries.isEmpty ? null : () => _exportHistory(filteredEntries),
                icon: const Icon(Icons.ios_share),
              ),
            ],
            // The count reads clearly on its own line instead of shrinking the
            // whole title (including the accessory's own name) to fit.
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(32),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${filteredEntries.length} history report${filteredEntries.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                Expanded(
                  child: Stack(
                    children: [
                      FlutterMap(
                        key: ValueKey(MediaQuery.of(context).orientation),
                        mapController: _mapController,
                        options: MapOptions(
                          backgroundColor: Theme.of(context).colorScheme.surface,
                          initialCenter: const LatLng(51.1657, 10.4515),
                          maxZoom: 18.0,
                          minZoom: 2.0,
                          initialZoom: 13.0,
                          onMapReady: mapReadyInit,
                          interactionOptions: const InteractionOptions(
                              enableMultiFingerGestureRace: true,
                              flags: InteractiveFlag.pinchZoom |
                                  InteractiveFlag.drag |
                                  InteractiveFlag.doubleTapZoom |
                                  InteractiveFlag.scrollWheelZoom |
                                  InteractiveFlag.flingAnimation |
                                  InteractiveFlag.pinchMove |
                                  InteractiveFlag.pinchZoom),
                          onTap: (_, __) {
                            setState(() {
                              showPopup = false;
                              popupEntry = null;
                            });
                          },
                        ),
                        children: [
                          TileLayer(
                            tileProvider: NetworkTileProvider(),
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'de.dchristl.headlesshaystack',
                            // See map/map.dart for why this uses flutter_map's
                            // own darkModeTileBuilder rather than a plain invert.
                            tileBuilder:
                                Theme.of(context).brightness == Brightness.dark
                                    ? darkModeTileBuilder
                                    : null,
                          ),
                          // The line connecting the locations chronologically
                          PolylineLayer(
                            polylines: polylines,
                          ),
                          // The markers for the historic locations
                          MarkerLayer(
                            markers: filteredEntries
                                .map((entry) => Marker(
                                      point: entry.location,
                                      child: GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            showPopup = true;
                                            popupEntry = entry;
                                          });
                                        },
                                        child: Icon(
                                          Icons.circle,
                                          size: isPointLayerVisible
                                              ? calculateSize(entry)
                                              : 0,
                                          // indicatorColor was white in light
                                          // theme, invisible against the tiles;
                                          // it was fine in dark, but primary
                                          // reads well in both.
                                          color: entry == popupEntry
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .error
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                        ),
                                      ),
                                    ))
                                .toList(),
                          ),
                          // Displays the tooltip if active
                          MarkerLayer(
                            markers: [
                              if (showPopup)
                                LocationPopup(
                                    location: popupEntry!.location,
                                    time: popupEntry!.start,
                                    end: popupEntry!.end,
                                    ctx: context),
                            ],
                          ),
                          RichAttributionWidget(
                            alignment: AttributionAlignment.bottomLeft,
                            attributions: [
                              const TextSourceAttribution(
                                  '© OpenStreetMap contributors'),
                            ],
                          ),
                        ],
                      ),
                      // A plain layer overlay (see map/accessory_popup.dart's own
                      // note) renders flush against the map's corner with no
                      // inset or surface behind it - this sits outside
                      // FlutterMap's children instead, as a normal positioned
                      // overlay.
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          elevation: 4,
                          borderRadius: BorderRadius.circular(8),
                          child: ToggleButtons(
                            borderRadius: BorderRadius.circular(8),
                            isSelected: visibility,
                            onPressed: (int index) {
                              setState(() {
                                visibility[index] = !visibility[index];
                                isLineLayerVisible = visibility[0];
                                isPointLayerVisible = visibility[1];
                                showPopup = false;
                                popupEntry = null;
                              });
                            },
                            children: const [
                              Tooltip(
                                message: 'Show the connecting line',
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(Icons.timeline),
                                ),
                              ),
                              Tooltip(
                                message: 'Show individual location points',
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(Icons.scatter_plot_rounded),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (filteredEntries.isEmpty)
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 14),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              'No locations in the last '
                              '$numberOfDays day${numberOfDays == 1 ? '' : 's'}.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                DaysSelectionSlider(
                  numberOfDays: numberOfDays.toDouble(),
                  maxDays: _maxDays,
                  onChanged: (double newValue) {
                    setState(() {
                      showPopup = false;
                      popupEntry = null;
                      numberOfDays = newValue.toInt();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        mapReady();
                      });
                    });
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  double calculateSize(Pair<dynamic, dynamic> entry) {
    //Point gets larger every 6 hours
    var d = (entry.end.difference(entry.start).inHours / 6).floor() + 1;
    return min(d * 10, 40); // 4 steps is enough
  }

  void mapReady() {
    List<Pair<dynamic, dynamic>> filteredEntries = filterHistoryEntries();
    if (filteredEntries.isNotEmpty) {
      var historicLocations =
          filteredEntries.map((entry) => entry.location).toList();
      var bounds = LatLngBounds.fromPoints(historicLocations);
      _mapController.fitCamera(CameraFit.bounds(bounds: bounds));
    }
  }

  void mapReadyInit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mapReady();
    });
  }

  /// Reuses the dashboard's single-accessory refresh path, so this page
  /// gets the same feedback snackbars and Apple-session banner handling as
  /// the swipe-right refresh action, and the same shared in-flight state
  /// as every other Refresh action (see [RefreshCoordinator]).
  /// [widget.accessory] is the same instance the registry mutates in
  /// place, so the rebuild the coordinator triggers on completion is
  /// enough to pick up the newly fetched history - no local state needed.
  Future<void> _refresh() async {
    try {
      await widget.refreshCoordinator.refresh(widget.accessory);
    } catch (error, stackTrace) {
      // The coordinator's own try/finally already cleared the in-flight
      // flag regardless - this only stops the error from becoming an
      // unhandled exception, since onPressed is a plain void callback
      // with nothing else to hand it to.
      logger.e('Error refreshing accessory', error: error, stackTrace: stackTrace);
    }
  }

  /// Exports [entries] - the currently-filtered history, matching what's
  /// shown on the map - as a GPX file, shared via the OS share sheet (or
  /// downloaded directly on web, where there's no share sheet).
  Future<void> _exportHistory(List<Pair<dynamic, dynamic>> entries) async {
    var gpx = buildGpxDocument(widget.accessory.name, entries);
    var filename = gpxFilenameFor(widget.accessory.name);

    try {
      if (kIsWeb) {
        final blob = html.Blob([gpx], 'application/gpx+xml', 'native');
        final url = html.Url.createObjectUrlFromBlob(blob);

        html.AnchorElement(href: url)
          ..setAttribute('download', filename)
          ..click();

        html.Url.revokeObjectUrl(url);
      } else {
        Directory tempDir = await getTemporaryDirectory();
        File file = File('${tempDir.path}/$filename');
        await file.writeAsString(gpx);

        SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)], subject: filename),
        );
      }
    } catch (e, stacktrace) {
      logger.e('Error exporting history', error: e, stackTrace: stacktrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.error,
            content: Text(
              'Could not export history.',
              style: TextStyle(color: Theme.of(context).colorScheme.onError),
            ),
          ),
        );
      }
    }
  }

  List<Pair<dynamic, dynamic>> filterHistoryEntries() {
    var now = DateTime.now();
    var filteredEntries = widget.accessory
        .getSortedLocationHistory()
        .where(
          (element) => element.end.isAfter(
            now.subtract(Duration(days: numberOfDays.round())),
          ),
        )
        .toList();
    return filteredEntries;
  }

  var logger = Logger(
    printer: PrettyPrinter(methodCount: 0),
  );
}
