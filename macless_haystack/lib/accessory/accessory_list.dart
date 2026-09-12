import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_actions.dart';
import 'package:macless_haystack/accessory/accessory_list_item.dart';
import 'package:macless_haystack/accessory/accessory_list_item_placeholder.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/accessory/no_accessories.dart';
import 'package:macless_haystack/location/location_model.dart';

import '../callbacks.dart';
import 'accessory_model.dart';

/// The active accessories in [accessories], preserving their relative order.
List<Accessory> activeAccessories(Iterable<Accessory> accessories) {
  return accessories.where((accessory) => accessory.isActive).toList();
}

/// The inactive accessories in [accessories], preserving their relative
/// order.
List<Accessory> inactiveAccessories(Iterable<Accessory> accessories) {
  return accessories.where((accessory) => !accessory.isActive).toList();
}

/// The label shown (and announced) for a group header, e.g. 'Active (3)'.
String groupHeaderLabel(String title, int count) {
  return '$title ($count)';
}

/// Rebuilds the full accessory order after a drag-reorder within one group
/// (active or inactive).
///
/// The registry's storage layer only understands a single flat order, so the
/// other group's current order is preserved and spliced in front of or
/// behind the freshly reordered group.
List<Accessory> mergedOrderAfterGroupReorder({
  required List<Accessory> allAccessories,
  required List<Accessory> reorderedGroup,
  required bool reorderedGroupIsActive,
}) {
  if (reorderedGroupIsActive) {
    return [...reorderedGroup, ...inactiveAccessories(allAccessories)];
  }
  return [...activeAccessories(allAccessories), ...reorderedGroup];
}

class AccessoryList extends StatefulWidget {
  final LoadLocationUpdatesCallback loadLocationUpdates;
  final SaveOrderUpdatesCallback saveOrderUpdatesCallback;
  final void Function(LatLng point)? centerOnPoint;

  /// Display a location overview all accessories in a concise list form.
  ///
  /// For each accessory the name and last known locaiton information is shown.
  /// Uses the accessories in the [AccessoryRegistry].
  const AccessoryList({
    super.key,
    required this.loadLocationUpdates,
    this.centerOnPoint,
    required this.saveOrderUpdatesCallback,
  });

  @override
  State<StatefulWidget> createState() {
    return _AccessoryListState();
  }
}

class _AccessoryListState extends State<AccessoryList> {
  // Per-session UI state only, not persisted - a fresh State always starts
  // with both groups expanded.
  final Set<String> _collapsedGroups = {};

  @override
  Widget build(BuildContext context) {
    return Consumer2<AccessoryRegistry, LocationModel>(
      builder: (context, accessoryRegistry, locationModel, child) {
        var accessories = accessoryRegistry.accessories;

        // Show placeholder while accessories are loading
        if (accessoryRegistry.loading) {
          return LayoutBuilder(builder: (context, constraints) {
            // Show as many accessory placeholder fitting into the vertical space.
            // Minimum one, maximum 6 placeholders
            var nrOfEntries =
                min(max((constraints.maxHeight / 64).floor(), 1), 6);
            List<Widget> placeholderList = [];
            for (int i = 0; i < nrOfEntries; i++) {
              placeholderList.add(const AccessoryListItemPlaceholder());
            }
            return Scrollbar(
              child: ListView(
                // Both tabs stay mounted via IndexedStack, so this and the
                // Accessories tab's list would otherwise fight over the
                // shared PrimaryScrollController.
                primary: false,
                children: placeholderList,
              ),
            );
          });
        }

        if (accessories.isEmpty) {
          return const NoAccessoriesPlaceholder();
        }

        var active = activeAccessories(accessories);
        var inactive = inactiveAccessories(accessories);
        // A group that's empty can't show a header to re-expand, so drop
        // any stale collapsed flag now rather than surprising the user
        // with an already-collapsed section if it refills later.
        if (active.isEmpty) _collapsedGroups.remove('active');
        if (inactive.isEmpty) _collapsedGroups.remove('inactive');

        // Use pull to refresh method
        //
        // A single CustomScrollView with one SliverReorderableList per group
        // (rather than nesting two independently-scrolling
        // ReorderableListViews) so drag-to-edge auto-scroll works and the
        // list stays lazily built - both share this one Scrollable.
        return SlidableAutoCloseBehavior(
          child: Scrollbar(
            child: CustomScrollView(
              // Both tabs stay mounted via IndexedStack, so this and the
              // Accessories tab's list would otherwise fight over the
              // shared PrimaryScrollController.
              primary: false,
              slivers: [
                if (active.isNotEmpty)
                  ..._buildGroupSlivers(
                    keyPrefix: 'active',
                    title: 'Active',
                    group: active,
                    groupIsActive: true,
                    allAccessories: accessories,
                    locationModel: locationModel,
                  ),
                if (inactive.isNotEmpty)
                  ..._buildGroupSlivers(
                    keyPrefix: 'inactive',
                    title: 'Inactive',
                    group: inactive,
                    groupIsActive: false,
                    allAccessories: accessories,
                    locationModel: locationModel,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildGroupSlivers({
    required String keyPrefix,
    required String title,
    required List<Accessory> group,
    required bool groupIsActive,
    required List<Accessory> allAccessories,
    required LocationModel locationModel,
  }) {
    final isCollapsed = _collapsedGroups.contains(keyPrefix);
    final displayTitle = groupHeaderLabel(title, group.length);
    return [
      SliverToBoxAdapter(
        key: ValueKey('$keyPrefix-header'),
        child: Semantics(
          button: true,
          expanded: !isCollapsed,
          label: displayTitle,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () {
                setState(() {
                  // Read live rather than trusting the isCollapsed captured
                  // above the setState boundary, so this stays correct even
                  // if a future change starts mutating _collapsedGroups
                  // from somewhere else between builds.
                  if (!_collapsedGroups.remove(keyPrefix)) {
                    _collapsedGroups.add(keyPrefix);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: ExcludeSemantics(
                  child: Row(
                    children: [
                      Text(displayTitle,
                          style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(width: 4),
                      // expand_more starts pointing down (collapsed) and
                      // rotates to point up (expanded), matching
                      // ExpansionTile's convention.
                      AnimatedRotation(
                        turns: isCollapsed ? 0 : 0.5,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(Icons.expand_more),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      if (!isCollapsed)
        SliverReorderableList(
          key: ValueKey('$keyPrefix-list'),
          itemCount: group.length,
          itemBuilder: (context, index) {
            final accessory = group[index];
            return ReorderableDelayedDragStartListener(
              key: ValueKey(accessory),
              index: index,
              child: _buildAccessoryTile(accessory, locationModel),
            );
          },
          onReorderItem: (int oldIndex, int newIndex) {
            var copiedGroup = List<Accessory>.from(group);
            copiedGroup.insert(newIndex, copiedGroup.removeAt(oldIndex));
            widget.saveOrderUpdatesCallback(mergedOrderAfterGroupReorder(
              allAccessories: allAccessories,
              reorderedGroup: copiedGroup,
              reorderedGroupIsActive: groupIsActive,
            ));
          },
          // Unlike ReorderableListView, SliverReorderableList has no default
          // proxyDecorator - without one, the lifted item has no Material
          // ancestor once reparented into the overlay during a drag.
          proxyDecorator:
              (Widget child, int index, Animation<double> animation) {
            return AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                final elevation = lerpDouble(
                    0, 6, Curves.easeInOut.transform(animation.value))!;
                return Material(elevation: elevation, child: child);
              },
              child: child,
            );
          },
        ),
    ];
  }

  Widget _buildAccessoryTile(Accessory accessory, LocationModel locationModel) {
    // Calculate distance from users devices location
    Widget? trailing;
    if (locationModel.here != null && accessory.lastLocation != null) {
      const Distance distance = Distance();
      final double km = distance.as(
          LengthUnit.Kilometer, locationModel.here!, accessory.lastLocation!);
      trailing = Text('$km km');
    }
    // Get human readable location
    Widget tile = Slidable(
      key: ValueKey(accessory),
      startActionPane: !accessory.isActive
          ? null
          : ActionPane(
              key: ValueKey(accessory),
              motion: const ScrollMotion(),
              dragDismissible: false,
              children: [
                  SlidableAction(
                    onPressed: (context) async {
                      await widget.loadLocationUpdates(accessory);
                    },
                    // flutter_slidable defaults backgroundColor to a hardcoded
                    // white, which the dark-theme primary color is invisible on.
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    icon: Icons.refresh,
                    label: 'Refresh',
                  ),
                ]),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        children: [
          if (accessory.isActive)
            SlidableAction(
              onPressed: (context) => navigateToAccessory(accessory),
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              foregroundColor: Theme.of(context).colorScheme.primary,
              icon: Icons.directions,
              label: 'Navigate',
            ),
          if (accessory.isActive)
            SlidableAction(
              onPressed: (context) => openAccessoryHistory(context, accessory),
              backgroundColor: Theme.of(context).colorScheme.primary,
              icon: Icons.history,
              label: 'History',
            ),
          if (accessory.isActive)
            SlidableAction(
              onPressed: (context) => shareAccessoryLocation(accessory),
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              foregroundColor: Theme.of(context).colorScheme.primary,
              icon: Icons.share,
              label: 'Share',
            ),
          if (!accessory.isActive)
            SlidableAction(
              onPressed: (context) {
                var accessoryRegistry =
                    Provider.of<AccessoryRegistry>(context, listen: false);
                var newAccessory = accessory.clone();
                newAccessory.isActive = true;
                accessoryRegistry.editAccessory(accessory, newAccessory);
              },
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              icon: Icons.toggle_on_outlined,
              label: 'Activate',
            ),
        ],
      ),
      child: Builder(builder: (context) {
        return AccessoryListItem(
          accessory: accessory,
          distance: trailing,
          herePlace: locationModel.herePlace,
          onTap: () {
            if (accessory.isActive) {
              var lastLocation = accessory.lastLocation;
              if (lastLocation != null) {
                widget.centerOnPoint?.call(lastLocation);
              }
            }
          },
          onLongPress: !accessory.isActive
              ? null
              : () async {
                  await widget.loadLocationUpdates(accessory);
                },
        );
      }),
    );

    // The Active/Inactive grouping conveys this visually, but a screen
    // reader has no other way to know - the greyed-out name is color-only.
    if (!accessory.isActive) {
      tile = Semantics(label: 'Inactive', child: tile);
    }
    return tile;
  }
}
