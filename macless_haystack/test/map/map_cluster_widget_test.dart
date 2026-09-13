import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/map/map.dart';

/// Regression test for a real crash: flutter_map_marker_cluster invokes
/// onMarkersClustered synchronously from inside its own build() (when a
/// zoom-out animation merges markers into a cluster), so calling setState
/// directly from that callback throws "setState() or markNeedsBuild()
/// called during build". This wires onMarkersClustered exactly the way
/// _AccessoryMapState does - deferring the setState via
/// WidgetsBinding.instance.addPostFrameCallback - using the real
/// clusterAbsorbedSelection predicate from lib/map/map.dart, inside a
/// minimal FlutterMap tree that reproduces the same clustering setup
/// (not the full AccessoryMap widget, which needs Provider/plugin
/// scaffolding well beyond what this specific hazard needs).
void main() {
  testWidgets(
      'zooming out to merge the selected marker into a cluster does not throw',
      (tester) async {
    var mapController = MapController();
    String? selectedId = 'a';

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return FlutterMap(
              mapController: mapController,
              options: const MapOptions(
                initialCenter: LatLng(0, 0),
                initialZoom: 18,
                minZoom: 2,
                maxZoom: 18,
              ),
              children: [
                MarkerClusterLayerWidget(
                  options: MarkerClusterLayerOptions(
                    maxClusterRadius: 45,
                    size: const Size(44, 44),
                    maxZoom: 18,
                    disableClusteringAtZoom: 15,
                    markers: [
                      Marker(
                        key: const ValueKey('a'),
                        point: const LatLng(0, 0),
                        child: const SizedBox(),
                      ),
                      Marker(
                        key: const ValueKey('b'),
                        point: const LatLng(0.0001, 0.0001),
                        child: const SizedBox(),
                      ),
                    ],
                    builder: (context, markers) =>
                        Text('${markers.length}', textDirection: TextDirection.ltr),
                    onMarkersClustered: (mergedMarkers) {
                      if (!clusterAbsorbedSelection(mergedMarkers, selectedId)) {
                        return;
                      }
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        setState(() => selectedId = null);
                      });
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );

    // Zoom out sharply enough that both markers fall inside the same
    // cluster - this is what triggers the zoom-out animation path that
    // calls onMarkersClustered from inside the layer's own build().
    for (var zoom = 17; zoom >= 2; zoom--) {
      mapController.move(const LatLng(0, 0), zoom.toDouble());
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(selectedId, isNull);
  });
}
