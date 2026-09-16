import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';

/// The accessories among [accessories] whose tags actually change when
/// [oldTag] is renamed to [newTag] (accessories without [oldTag] are
/// omitted - nothing to update), with that change already applied.
/// Renaming to a tag the accessory already has collapses to one entry
/// rather than creating a duplicate.
List<Accessory> accessoriesAfterTagRename(
  List<Accessory> accessories,
  String oldTag,
  String newTag,
) {
  var changed = <Accessory>[];
  for (var accessory in accessories) {
    if (!accessory.tags.contains(oldTag)) continue;
    var updated = accessory.clone();
    updated.tags = accessory.tags
        .map((tag) => tag == oldTag ? newTag : tag)
        .toSet()
        .toList();
    changed.add(updated);
  }
  return changed;
}

/// The accessories among [accessories] that have [tag], with it removed.
/// Accessories without [tag] are omitted.
List<Accessory> accessoriesAfterTagDelete(
  List<Accessory> accessories,
  String tag,
) {
  var changed = <Accessory>[];
  for (var accessory in accessories) {
    if (!accessory.tags.contains(tag)) continue;
    var updated = accessory.clone();
    updated.tags = accessory.tags.where((t) => t != tag).toList();
    changed.add(updated);
  }
  return changed;
}

/// Lists every tag currently in use, with rename/delete actions that
/// apply across every accessory that has it.
class TagManagementScreen extends StatelessWidget {
  const TagManagementScreen({super.key});

  Future<void> _rename(BuildContext context, String oldTag) async {
    var controller = TextEditingController(text: oldTag);
    try {
      var newTag = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Rename tag'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                var trimmed = controller.text.trim();
                if (trimmed.isNotEmpty) {
                  Navigator.pop(dialogContext, trimmed);
                }
              },
              child: const Text('Rename'),
            ),
          ],
        ),
      );
      if (newTag == null || newTag == oldTag || !context.mounted) return;

      var registry = Provider.of<AccessoryRegistry>(context, listen: false);
      var updates = accessoriesAfterTagRename(registry.accessories, oldTag, newTag);
      for (var i = 0; i < updates.length; i++) {
        var original = registry.accessories
            .firstWhere((accessory) => accessory.id == updates[i].id);
        registry.editAccessory(original, updates[i]);
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _delete(BuildContext context, String tag) async {
    var registry = Provider.of<AccessoryRegistry>(context, listen: false);
    var affectedCount =
        registry.accessories.where((a) => a.tags.contains(tag)).length;

    var confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete tag?'),
            content: Text(
                'This removes "$tag" from $affectedCount '
                '${affectedCount == 1 ? 'accessory' : 'accessories'}.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;

    var updates = accessoriesAfterTagDelete(registry.accessories, tag);
    for (var i = 0; i < updates.length; i++) {
      var original = registry.accessories
          .firstWhere((accessory) => accessory.id == updates[i].id);
      registry.editAccessory(original, updates[i]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage tags')),
      body: Consumer<AccessoryRegistry>(
        builder: (context, registry, child) {
          var tags = registry.allTags.toList()..sort();
          if (tags.isEmpty) {
            return const Center(child: Text('No tags yet.'));
          }
          return ListView(
            children: tags
                .map((tag) => ListTile(
                      title: Text(tag),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Rename',
                            icon: const Icon(Icons.edit),
                            onPressed: () => _rename(context, tag),
                          ),
                          IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, tag),
                          ),
                        ],
                      ),
                    ))
                .toList(),
          );
        },
      ),
    );
  }
}
