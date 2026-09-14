import 'package:flutter/material.dart';
import 'package:macless_haystack/map/map_tile_provider_model.dart';
import 'package:macless_haystack/map/map_tile_source.dart';
import 'package:provider/provider.dart';

/// Display labels for each map style, shared between this on-map picker
/// and the Settings page's own dropdown so the two can never show
/// different wording for the same underlying value.
const Map<String, String> mapTileProviderLabels = {
  mapTileProviderOsmValue: 'OpenStreetMap',
  mapTileProviderOpenTopoValue: 'OpenTopoMap (terrain)',
  mapTileProviderCartoVoyagerValue: 'CARTO Voyager',
  mapTileProviderCartoDarkValue: 'CARTO Dark Matter',
};

/// A small floating button overlaid on the map that opens a dropdown to
/// switch [mapTileProviderKey] without leaving the map.
///
/// Reads and writes the same [MapTileProviderModel] as the Settings > Map
/// dropdown, so switching here also updates the Settings page and vice
/// versa.
class MapStylePickerButton extends StatelessWidget {
  const MapStylePickerButton({super.key});

  @override
  Widget build(BuildContext context) {
    var value = context.watch<MapTileProviderModel>().value;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 4,
      child: PopupMenuButton<String>(
        tooltip: 'Change map style',
        icon: Icon(
          Icons.layers_outlined,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        initialValue: value,
        onSelected: (newValue) =>
            context.read<MapTileProviderModel>().setValue(newValue),
        itemBuilder: (context) => mapTileProviderLabels.entries
            .map(
              (entry) => CheckedPopupMenuItem<String>(
                value: entry.key,
                checked: entry.key == value,
                child: Text(entry.value),
              ),
            )
            .toList(),
      ),
    );
  }
}
