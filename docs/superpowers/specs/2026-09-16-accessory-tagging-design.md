# Accessory tagging and filtering

## Motivation

Accessories today have a name, icon, and color, but no way to organize them beyond that - a user with several tracked items (keys, car, kids' bags) has no way to group or filter them. Other tracker apps (Life360, Tile) let users tag/categorize items for exactly this. This adds free-form, multi-value tags per accessory, a way to filter accessory views by tag, and a screen to rename/delete a tag across every accessory that has it.

## Non-goals

- No first-class `Tag` entity with its own id/storage. Tags are plain strings living directly on `Accessory.tags`, matching how this app already stores everything else (color, icon, name) as flat per-accessory fields, not as references into a separate table.
- No tag filter row inside the map's bottom-sheet accessory list (`AccessoryList`/`accessory_list_item.dart`) - that widget is already space-constrained at its "peek" height. The filter lives only in the dedicated Accessories tab. Tag *badges* (read-only display) still appear in both places.
- No server-side changes. Tags are client-only data, same storage layer (`flutter_secure_storage`) as everything else on `Accessory`.

## Correcting an assumption from brainstorming

The "Accessories tab" and "the map's bottom-sheet accessory list" are two different widgets, not the same one reused twice:

- **Map tab's bottom sheet** (`lib/dashboard/accessory_map_list_vert.dart`) embeds `AccessoryList`/`accessory_list_item.dart` (`lib/accessory/accessory_list.dart`) - the richer list with Active/Inactive sections, drag-reorder, distance, and battery status.
- **Accessories tab** (`lib/dashboard/dashboard.dart`'s second tab) is `KeyManagement` (`lib/item_management/item_management.dart`) - a separate, simpler flat `ListTile` list (icon, name, last-seen, export menu), with no grouping or drag-reorder.

Every design decision made during brainstorming still holds; this just corrects which file implements which piece. The tag filter row and its "Accessories tab only" scope apply to `KeyManagement`. Tag badges on each row apply to both `KeyManagement`'s `ListTile`s and `accessory_list_item.dart`'s rows (the latter only in non-compact display mode, matching that widget's existing compact/non-compact convention).

## Architecture

### Data model (`lib/accessory/accessory_model.dart`)

`Accessory` gains `List<String> tags`, following the exact pattern already used for `additionalKeys`:

- Required named constructor parameter (every call site must pass it - existing call sites in `item_creation.dart`, `item_import.dart`, `item_file_import.dart`, and test fixtures pass `tags: []` for a freshly-created accessory).
- Copied in `clone()` (post-construction assignment, since it's not part of the constructor's minimal "identity" shape any more than `additionalKeys` needing special handling there - actually `additionalKeys` *is* a constructor param and *is* copied via the constructor call in `clone()`, so `tags` follows that same route: added to the constructor call in `clone()` directly, not as a separate post-construction assignment).
- Copied in `update()` (added alongside `additionalKeys = newAccessory.additionalKeys;` - tags are identity data a user edits, not a runtime-only marker like `lastNotifiedBatteryStatus`).
- Serialized in `toJson`/`fromJson` the same null-safe way as `additionalKeys`: `'tags': tags` in `toJson` (always present, defaults to `[]`, no need for the optional-key omission pattern `lastBatteryStatus` uses since an empty list is a perfectly normal JSON value, not something to hide), and `tags: json['tags']?.cast<String>() ?? List.empty()` in `fromJson` - existing saved accessories deserialize with an empty tag list, no migration step.

### Derived tag registry (`lib/accessory/accessory_registry.dart`)

```dart
/// Every tag currently used by at least one accessory, for autocomplete
/// suggestions and the tag management screen. Derived, not stored - there
/// is no tag that exists independently of the accessories using it.
Set<String> get allTags =>
    accessories.expand((accessory) => accessory.tags).toSet();
```

### Filter state (`lib/accessory/accessory_registry.dart`)

```dart
/// Tags currently selected to filter accessory views by. Empty means no
/// filter - every accessory matches. Session-only (not persisted) -
/// resets to no filter on app restart, matching how the map's own pan/zoom
/// state isn't persisted either.
Set<String> activeTagFilter = {};

/// Toggles [tag] in or out of [activeTagFilter] and notifies listeners.
void toggleTagFilter(String tag) {
  if (activeTagFilter.contains(tag)) {
    activeTagFilter.remove(tag);
  } else {
    activeTagFilter.add(tag);
  }
  notifyListeners();
}
```

### Filter predicate (`lib/accessory/accessory_list.dart` - already the home of the existing `activeAccessories`/`inactiveAccessories`/`groupHeaderLabel` free functions, so this joins them rather than starting a new file for one function)

```dart
/// Whether [accessory] matches [activeFilter] - true if the filter is
/// empty (no filter applied) or the accessory has at least one of the
/// selected tags (OR semantics, the standard filter-chip convention: more
/// selected tags broadens results, it doesn't narrow them).
bool matchesTagFilter(Accessory accessory, Set<String> activeFilter) {
  return activeFilter.isEmpty ||
      accessory.tags.any((tag) => activeFilter.contains(tag));
}
```

## Tag input UI

**New file `lib/item_management/accessory_tags_input.dart`**, following the existing `AccessoryColorInput`/`AccessoryIconInput` convention (a stateful widget taking the current value and a `changeListener`, not a `Form`-integrated `onSaved`/`initialValue` pair like `AccessoryNameInput` - color/icon are the closer precedent since tags, like them, need to push updates immediately in the edit screen rather than wait for form submission):

```dart
class AccessoryTagsInput extends StatefulWidget {
  final List<String> initialTags;
  final ValueChanged<List<String>> changeListener;

  const AccessoryTagsInput({
    super.key,
    required this.initialTags,
    required this.changeListener,
  });

  @override
  State<AccessoryTagsInput> createState() => _AccessoryTagsInputState();
}
```

Renders the current tags as a `Wrap` of `Chip`s (each with `onDeleted` removing that tag and calling `changeListener` with the updated list), plus a `TextField` wrapped in Flutter's built-in `Autocomplete<String>` widget (no new dependency) whose `optionsBuilder` filters `Provider.of<AccessoryRegistry>(context, listen: false).allTags` by the current input text. Submitting the text field (via `onFieldSubmitted` or selecting an autocomplete option) adds the trimmed, non-empty tag to the list if it isn't already present (case-sensitive exact match - no fuzzy dedup), clears the input, and calls `changeListener`.

**Wired into `lib/item_management/item_creation.dart`**: added to the `Column` alongside `AccessoryIconInput`/`AccessoryColorInput`, with `initialTags: newAccessory.tags` (starts as `[]`, set in the constructor call at the top of `_AccessoryGenerationState`) and `changeListener: (tags) => setState(() => newAccessory.tags = tags)`.

**Wired into `lib/accessory/accessory_detail.dart`**: added alongside `AccessoryNameInput`, with `initialTags: newAccessory.tags` and a `changeListener` that follows the exact pattern the adjacent `isActive` `SwitchListTile` already uses - clone the currently-saved accessory, apply the new tags, and call `accessoryRegistry.editAccessory(widget.accessory, updatedAccessory)` immediately (not deferred to a save button), so tag edits persist the same way an active/inactive toggle already does on that screen.

## Tag display

**`lib/item_management/item_management.dart` (`KeyManagement`)**: each `ListTile`'s `subtitle` becomes a `Column` with the existing "Last seen: ..." `Text` plus, when `accessory.tags` is non-empty, a `Wrap` of small read-only `Chip`s (no delete icon here - this is a display-only list, editing happens on the detail screen) below it.

**`lib/accessory/accessory_list_item.dart`**: when not in compact mode (`isCompact == false`) and `accessory.tags` is non-empty, a `Wrap` of small read-only `Chip`s renders below the existing subtitle content. Compact mode (`isCompact == true`) is unchanged - that mode's entire purpose is fitting icon/name/distance/last-seen on one line, and tags don't fit that goal.

## Filtering

### `KeyManagement` (the Accessories tab)

At the top of the `Consumer<AccessoryRegistry>` builder, alongside the existing `var accessories = accessoryRegistry.accessories;`:

```dart
var allAccessories = accessoryRegistry.accessories;
var accessories = allAccessories
    .where((a) => matchesTagFilter(a, accessoryRegistry.activeTagFilter))
    .toList();
```

- The existing `accessories.isEmpty` check (which currently distinguishes "still loading" from "no accessories at all") now checks `allAccessories.isEmpty` instead, so it only fires for the genuine zero-accessories case.
- A new check: if `accessories.isEmpty && allAccessories.isNotEmpty` (filter active, nothing matches), show a plain centered `Text('No accessories match the selected tags.')` instead of the `ListView` - the filter chip row (below) still renders above it so the user can clear the filter without leaving the screen.
- A new `Wrap` of `FilterChip`s renders above the list/placeholder, one per tag in `accessoryRegistry.allTags`, `selected: accessoryRegistry.activeTagFilter.contains(tag)`, `onSelected: (_) => accessoryRegistry.toggleTagFilter(tag)`. Omitted entirely (no `Wrap`, no reserved space) when `allTags` is empty - no tags exist yet, nothing to filter by.

### Map (`lib/map/map.dart`)

Every place `accessoryRegistry.accessories` is read for rendering/camera-fitting purposes gets tag-filtered at the source, so every downstream function (`shouldFitToAccessoryLocations`, `fitToContent`, `selectedAccessory`, `accessoryMarkers` via `_accessoryMarkersFor`) automatically respects the filter without any of those functions' own signatures or internal `.where((accessory) => accessory.isActive)` calls needing to change - they already operate on whatever list they're handed.

A private helper in `_AccessoryMapState`:

```dart
/// The accessories to actually render/fit-to, after the active tag filter
/// (empty filter = everything). Centralizing this one filter step here
/// means accessoryMarkers, fitToContent, shouldFitToAccessoryLocations,
/// and selectedAccessory need no changes of their own - they already just
/// operate on whatever accessories list they're handed.
List<Accessory> _tagFilteredAccessories(AccessoryRegistry registry) {
  return registry.accessories
      .where((a) => matchesTagFilter(a, registry.activeTagFilter))
      .toList();
}
```

Applied at all 4 existing read sites:
- `initState()`'s three direct reads (`shouldFitToAccessoryLocations(accessoryRegistry.accessories, ...)`, the two `fitToContent(accessoryRegistry.accessories, ...)` calls) become `_tagFilteredAccessories(accessoryRegistry)`.
- `build()`'s `var accessories = accessoryRegistry.accessories;` becomes `var accessories = _tagFilteredAccessories(accessoryRegistry);` - this one line already feeds `shouldFitToAccessoryLocations`, `fitToContent`, `selectedAccessory`, and (via `_accessoryMarkersFor(accessories)`) the actual marker rendering, so no other line in `build()` needs to change.

## Tag management screen

**New file `lib/item_management/tag_management.dart`**: a `Scaffold` with a `ListView` of every tag in `accessoryRegistry.allTags` (alphabetically sorted), each row a `ListTile` with the tag name and two trailing `IconButton`s (edit/rename, delete).

- **Rename**: opens a dialog with a pre-filled text field (existing tag name). On confirm with a non-empty, changed value: for every accessory in `accessoryRegistry.accessories` whose `tags` contains the old name, build an updated tag list (`tags.map((t) => t == oldName ? newName : t).toSet().toList()` - routing through a `Set` first collapses the case where the accessory already had the new name too, avoiding a duplicate entry) and call `accessoryRegistry.editAccessory(accessory, updated)` for each. Rejects (shows an inline error, no navigation) an empty/whitespace-only new name.
- **Delete**: opens a confirmation dialog naming the tag and how many accessories have it. On confirm: for every accessory whose `tags` contains it, call `editAccessory` with that tag removed from its list.

**Entry point**: `lib/dashboard/dashboard.dart`'s shared `AppBar`'s `actions` list gains a new conditional branch, `if (_selectedIndex == 1)` (the Accessories tab - mirroring the existing `if (_selectedIndex == 0)` branch that adds the Map tab's "Force fetch from Apple" `PopupMenuButton`), containing an `IconButton` (`Icons.label_outline`, tooltip `'Manage tags'`) that pushes `TagManagementScreen`.

## Error handling

No new failure modes. Tag edits go through the same `editAccessory`/`_storeAccessories` path every other accessory edit already uses, so a storage failure surfaces (or doesn't - existing behavior, unchanged) exactly the same way an existing name/color edit failure would.

## Testing

- `Accessory.toJson`/`fromJson`/`clone` round-trip tests for `tags`, extending the existing `accessory_model_test.dart` pattern: a set tag list round-trips unchanged; an accessory with no `tags` key in its JSON (simulating pre-this-feature saved data) deserializes to `[]`, not a crash.
- `matchesTagFilter`: pure function, unit tests - empty filter matches everything; a filter with one tag matches accessories having that tag (among possibly others) and excludes accessories without it; a filter with multiple tags matches an accessory having any one of them (OR semantics).
- `AccessoryRegistry.allTags`: unit test - the union of tags across several accessories, deduplicated, including the case of zero accessories or all accessories having no tags (empty set, not an error).
- `AccessoryRegistry.toggleTagFilter`: unit test - toggling a tag on adds it and notifies; toggling it again removes it.
- Rename/delete batch-update logic: unit-testable directly against `AccessoryRegistry` (matching this file's existing test style) - build a registry with several accessories with overlapping tags, invoke the same logic the tag management screen's rename/delete handlers use, assert the resulting `tags` list on each accessory. (If the rename/delete logic ends up living as private handler code inside the `TagManagementScreen` widget rather than a separate testable function, extract it as a small top-level function in `tag_management.dart` first - e.g. `List<Accessory> accessoriesAfterTagRename(List<Accessory> accessories, String oldName, String newName)` - so this stays testable without pumping a widget tree, matching how this session's other features (e.g. `resolveNotifiedAccessoryLocation`) extracted pure logic out of widget code specifically to keep it testable.)
- UI wiring (chip input, autocomplete, filter row, map marker filtering, the tag management screen itself) is manually verified on-device, consistent with how UI-glue has been verified for every feature this session.

## Follow-ups (explicitly out of scope here)

- Persisting `activeTagFilter` across app restarts.
- A tag filter in the map's bottom-sheet list.
- Any tag-based feature beyond filtering/organization (e.g. per-tag notification settings, per-tag map styling).
