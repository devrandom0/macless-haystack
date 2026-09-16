import 'package:universal_io/io.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_detail.dart';
import 'package:macless_haystack/accessory/accessory_icon.dart';
import 'package:macless_haystack/accessory/accessory_list.dart';
import 'package:macless_haystack/accessory/no_accessories.dart';
import 'package:macless_haystack/item_management/item_export.dart';
import 'package:macless_haystack/item_management/loading_spinner.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/util/time_format.dart';
import 'package:intl/intl.dart';

class KeyManagement extends StatelessWidget {
  /// Displays a list of all accessories.
  ///
  /// Each accessory can be exported and is linked to a detail page.
  const KeyManagement({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AccessoryRegistry>(
      builder: (context, accessoryRegistry, child) {
        var allAccessories = accessoryRegistry.accessories;
        var accessories = allAccessories
            .where((a) => matchesTagFilter(a, accessoryRegistry.activeTagFilter))
            .toList();

        if (allAccessories.isEmpty) {
          // Distinguish "still loading, nothing fetched yet" from "loaded,
          // genuinely no accessories" - without this the empty state flashes
          // on every launch before the first load finishes.
          if (!accessoryRegistry.initialLoadFinished) {
            return const LoadingSpinner();
          }
          return const NoAccessoriesPlaceholder();
        }

        var sortedTags = accessoryRegistry.allTags.toList()..sort();
        var filterRow = sortedTags.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Wrap(
                  spacing: 8,
                  children: sortedTags
                      .map((tag) => FilterChip(
                            label: Text(tag),
                            selected:
                                accessoryRegistry.activeTagFilter.contains(tag),
                            onSelected: (_) =>
                                accessoryRegistry.toggleTagFilter(tag),
                          ))
                      .toList(),
                ),
              );

        if (accessories.isEmpty) {
          return Column(
            children: [
              if (filterRow != null) filterRow,
              const Expanded(
                child: Center(
                  child: Text('No accessories match the selected tags.'),
                ),
              ),
            ],
          );
        }

        return Column(
          children: [
            if (filterRow != null) filterRow,
            Expanded(
              child: Scrollbar(
                child: ListView(
                  // Both tabs stay mounted via IndexedStack, so this and the
                  // Map tab's list would otherwise fight over the shared
                  // PrimaryScrollController.
                  primary: false,
                  children: accessories.map((accessory) {
                    String lastSeen = accessory.datePublished != null &&
                            accessory.datePublished != DateTime(1970)
                        ? '${DateFormat.yMMMd(Platform.localeName).format(accessory.datePublished!)} '
                            '${formatTime(accessory.datePublished!)}'
                        : 'Never';
                    return Material(
                        child: ListTile(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) => AccessoryDetail(
                                    accessory: accessory,
                                  )),
                        );
                      },
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      minVerticalPadding: 0,
                      title: Text(accessory.name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Last seen: $lastSeen'),
                          if (accessory.tags.isNotEmpty)
                            Wrap(
                              spacing: 4,
                              children: accessory.tags
                                  .map((tag) => Chip(
                                        label: Text(tag,
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall),
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ))
                                  .toList(),
                            ),
                        ],
                      ),
                      leading: AccessoryIcon(
                        icon: accessory.icon,
                        color: accessory.color,
                        size: 20,
                      ),
                      trailing: ItemExportMenu(accessory: accessory),
                    ));
                  }).toList(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
