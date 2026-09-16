# Accessory Tagging and Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user tag accessories with free-form labels, filter the Accessories tab and the map by tag, and rename/delete a tag across every accessory that has it.

**Architecture:** Tags are a plain `List<String>` field directly on `Accessory` (no separate tag entity/storage), with the "known tags" set and active filter derived/held on `AccessoryRegistry`. A pure `matchesTagFilter` predicate is shared by the Accessories tab's list and the map's marker rendering.

**Tech Stack:** Flutter/Dart, Flutter's built-in `Autocomplete` widget (no new dependency).

**Spec:** docs/superpowers/specs/2026-09-16-accessory-tagging-design.md

## Global Constraints

- Tags are case-sensitive, free-form strings. No fuzzy dedup - adding a tag that already exists on the accessory (exact string match) is a no-op.
- The tag filter uses OR semantics: with N tags selected, an accessory matching *any* of them is shown.
- No new dependency for the autocomplete input - use Flutter's built-in `Autocomplete<String>` widget.
- The tag filter row appears only in the Accessories tab (`KeyManagement`), never in the map's bottom-sheet list (`AccessoryList`/`accessory_list_item.dart`) - that widget stays exactly as it is except for read-only tag badges.
- **Deviation from the spec's literal wording, recorded here for the whole-branch review:** the spec describes `tags` as a `required` constructor parameter, mirroring `additionalKeys`. This plan makes it an *optional* parameter defaulting to `const []` instead. Reason: a required parameter would force updating every existing `Accessory(...)` construction site across the codebase - 3 in `lib/` (`item_creation.dart`, `item_import.dart`, `item_file_import.dart`) and 12 more across 5 test files (`test/map/map_test.dart`, `test/accessory/accessory_model_test.dart` ×2, `test/accessory/accessory_list_grouping_test.dart`, `test/accessory/accessory_registry_test.dart` ×7, `test/notifications/notification_navigation_test.dart`) - a large, purely mechanical, easy-to-miss-one diff for zero behavioral gain over a default. The default achieves the identical runtime behavior (every accessory has a `tags` list, empty unless set) with zero risk of a forgotten call site breaking compilation. `clone()` still explicitly passes `tags: tags` (see Task 1) so cloning doesn't silently drop existing tags back to the default.

---

### Task 1: `Accessory.tags` field

**Files:**
- Modify: `lib/accessory/accessory_model.dart`
- Test: `test/accessory/accessory_model_test.dart`

**Interfaces:**
- Produces: `Accessory.tags` (`List<String>`, defaults to `const []`), read/written directly by later tasks.

- [ ] **Step 1: Write the failing tests**

Add to `test/accessory/accessory_model_test.dart` (below the existing tests, using the file's existing `buildAccessory`/`buildAccessoryWithBattery` helper style):

```dart
  Accessory buildAccessoryWithTags(List<String> tags) {
    final accessory = Accessory(
        id: '1',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: List.empty(),
        tags: tags);
    return accessory;
  }

  test('an accessory with no tags argument defaults to an empty list', () {
    final accessory = Accessory(
        id: '1',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: List.empty());

    expect(accessory.tags, isEmpty);
  });

  test('toJson/fromJson round-trips tags', () {
    final accessory = buildAccessoryWithTags(['Keys', 'Car']);

    final restored = Accessory.fromJson(accessory.toJson());

    expect(restored.tags, ['Keys', 'Car']);
  });

  test('fromJson defaults to an empty list when tags is absent from the JSON', () {
    final accessory = buildAccessoryWithTags(['Keys']);
    final json = accessory.toJson();
    json.remove('tags');

    final restored = Accessory.fromJson(json);

    expect(restored.tags, isEmpty);
  });

  test('clone copies tags', () {
    final accessory = buildAccessoryWithTags(['Keys']);

    final cloned = accessory.clone();

    expect(cloned.tags, ['Keys']);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/accessory/accessory_model_test.dart`
Expected: FAIL - `tags` isn't a parameter/field of `Accessory`.

- [ ] **Step 3: Implement the field**

In `lib/accessory/accessory_model.dart`:

1. Add the field next to `additionalKeys` (around line 55):

```dart
  List<String> additionalKeys;

  /// Free-form labels the user has assigned to organize/filter this
  /// accessory (e.g. "Keys", "Car"). Case-sensitive; empty means untagged.
  List<String> tags;
```

2. Add the constructor parameter, as an optional parameter defaulting to `const []` (see the Global Constraints note on why this isn't `required` like `additionalKeys`):

```dart
  Accessory(
      {required this.id,
      required this.name,
      required this.hashedPublicKey,
      required this.datePublished,
      this.isActive = true,
      LatLng? lastLocation,
      String icon = 'mappin',
      this.color = Colors.grey,
      required this.additionalKeys,
      required this.hashesWithTS,
      required this.lastBatteryStatus,
      required this.locationHistory,
      this.tags = const []})
      : _icon = icon,
        _lastLocation = lastLocation,
        super() {
    _init();
  }
```

3. In `clone()`, add `tags: tags` to the constructor call (not a post-construction assignment like `lastNotifiedBatteryStatus` - `tags` is identity data set at construction, like `additionalKeys`):

```dart
  Accessory clone() {
    var cloned = Accessory(
        datePublished: datePublished,
        id: id,
        name: name,
        hashedPublicKey: hashedPublicKey,
        color: color,
        icon: _icon,
        isActive: isActive,
        lastLocation: lastLocation,
        hashesWithTS: hashesWithTS,
        additionalKeys: additionalKeys,
        locationHistory: locationHistory,
        lastBatteryStatus: lastBatteryStatus,
        tags: tags);
    cloned.lastNotifiedBatteryStatus = lastNotifiedBatteryStatus;
    return cloned;
  }
```

4. In `update()`, add alongside `additionalKeys`:

```dart
  void update(Accessory newAccessory) {
    id = newAccessory.id;
    name = newAccessory.name;
    hashedPublicKey = newAccessory.hashedPublicKey;
    color = newAccessory.color;
    _icon = newAccessory._icon;
    isActive = newAccessory.isActive;
    hashesWithTS = newAccessory.hashesWithTS;
    locationHistory = newAccessory.locationHistory;
    additionalKeys = newAccessory.additionalKeys;
    tags = newAccessory.tags;
  }
```

5. In `Accessory.fromJson`, add after the existing `additionalKeys` initializer (still inside the initializer list, comma-separated - note the existing `additionalKeys` initializer currently has no trailing comma since it's last; add one):

```dart
        additionalKeys =
            json['additionalKeys']?.cast<String>() ?? List.empty(),
        tags = json['tags']?.cast<String>() ?? List.empty() {
    _init();
  }
```

6. In `toJson()`, add `'tags': tags,` alongside `'additionalKeys': additionalKeys,` (always present, unlike the optional-key pattern used for `lastBatteryStatus` - an empty list is a normal value here, not something to omit):

```dart
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hashedPublicKey': hashedPublicKey,
        'datePublished': datePublished?.millisecondsSinceEpoch,
        'latitude': _lastLocation?.latitude,
        'longitude': _lastLocation?.longitude,
        'isActive': isActive,
        'icon': _icon,
        'color': color.toARGB32().toRadixString(16).padLeft(8, '0'),
        'hashesWithTS': jsonEncode(hashesWithTS),
        'additionalKeys': additionalKeys,
        'tags': tags,
        ...lastBatteryStatus != null
            ? {'lastBatteryStatus': lastBatteryStatus!.name}
            : {},
        ...lastNotifiedBatteryStatus != null
            ? {'lastNotifiedBatteryStatus': lastNotifiedBatteryStatus!.name}
            : {}
      };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/accessory/accessory_model_test.dart`
Expected: PASS (all existing tests plus the 4 new ones)

- [ ] **Step 5: Run the full suite to confirm no existing constructor call site broke**

Run: `flutter test`
Expected: PASS - since `tags` defaults to `const []`, none of the existing `Accessory(...)` call sites (production or test) need any change.

- [ ] **Step 6: Commit**

```bash
git add lib/accessory/accessory_model.dart test/accessory/accessory_model_test.dart
git commit -m "feat: add tags field to Accessory"
```

---

### Task 2: Registry tag state and the filter predicate

**Files:**
- Modify: `lib/accessory/accessory_registry.dart`
- Modify: `lib/accessory/accessory_list.dart`
- Test: `test/accessory/accessory_registry_test.dart`
- Test: `test/accessory/accessory_list_grouping_test.dart`

**Interfaces:**
- Consumes: `Accessory.tags` (Task 1).
- Produces:
  - `AccessoryRegistry.allTags` (getter, `Set<String>`), used by Task 3 (autocomplete) and Task 5 (filter chips)/Task 7 (tag management screen).
  - `AccessoryRegistry.activeTagFilter` (`Set<String>` field, starts empty) and `AccessoryRegistry.toggleTagFilter(String tag)`, used by Task 5 and Task 6.
  - `bool matchesTagFilter(Accessory accessory, Set<String> activeFilter)` - top-level function in `lib/accessory/accessory_list.dart`, used by Task 5 and Task 6.

- [ ] **Step 1: Write the failing tests**

Add to `test/accessory/accessory_list_grouping_test.dart` (this file already builds `Accessory` fixtures for grouping-related pure functions like `activeAccessories`/`inactiveAccessories` - `matchesTagFilter` joins them):

```dart
  group('matchesTagFilter', () {
    Accessory withTags(List<String> tags) => Accessory(
        id: '1',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: [],
        tags: tags);

    test('an empty filter matches every accessory', () {
      expect(matchesTagFilter(withTags([]), {}), isTrue);
      expect(matchesTagFilter(withTags(['Keys']), {}), isTrue);
    });

    test('matches an accessory having the one filtered tag', () {
      expect(matchesTagFilter(withTags(['Keys', 'Car']), {'Keys'}), isTrue);
    });

    test('does not match an accessory without any filtered tag', () {
      expect(matchesTagFilter(withTags(['Car']), {'Keys'}), isFalse);
    });

    test('matches an accessory having any one of multiple filtered tags', () {
      expect(
          matchesTagFilter(withTags(['Car']), {'Keys', 'Car'}), isTrue);
    });
  });
```

Check the top of `test/accessory/accessory_list_grouping_test.dart` for its existing imports of `accessory_list.dart` and `accessory_model.dart` before adding this - reuse them rather than duplicating.

Add to `test/accessory/accessory_registry_test.dart` (inside the existing top-level `main()`, alongside the other tests, using the shared `registry` fixture already set up there):

```dart
  group('tags', () {
    test('allTags is empty when no accessory has any tags', () {
      expect(registry.allTags, isEmpty);
    });

    test('allTags is the union of every accessory\'s tags, deduplicated', () {
      var a = Accessory(
          id: 'a',
          name: 'A',
          hashedPublicKey: '',
          datePublished: null,
          hashesWithTS: {},
          locationHistory: [],
          lastBatteryStatus: null,
          additionalKeys: [],
          tags: ['Keys', 'Car']);
      var b = Accessory(
          id: 'b',
          name: 'B',
          hashedPublicKey: '',
          datePublished: null,
          hashesWithTS: {},
          locationHistory: [],
          lastBatteryStatus: null,
          additionalKeys: [],
          tags: ['Car']);
      registry.addAccessory(a);
      registry.addAccessory(b);

      expect(registry.allTags, {'Keys', 'Car'});

      registry.removeAccessory(a);
      registry.removeAccessory(b);
    });

    test('toggleTagFilter adds then removes a tag from activeTagFilter', () {
      expect(registry.activeTagFilter, isEmpty);

      registry.toggleTagFilter('Keys');
      expect(registry.activeTagFilter, {'Keys'});

      registry.toggleTagFilter('Keys');
      expect(registry.activeTagFilter, isEmpty);
    });
  });
```

(These tests add/remove their own accessories rather than relying on the shared fixture's single `accessory`, and clean up after themselves, so they don't affect other tests in this file that assume a specific accessory count.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/accessory/accessory_list_grouping_test.dart test/accessory/accessory_registry_test.dart`
Expected: FAIL - `matchesTagFilter`, `allTags`, `activeTagFilter`, `toggleTagFilter` don't exist yet.

- [ ] **Step 3: Implement**

In `lib/accessory/accessory_list.dart`, add alongside the existing `activeAccessories`/`inactiveAccessories`/`groupHeaderLabel` free functions:

```dart
/// Whether [accessory] matches [activeFilter] - true if the filter is
/// empty (no filter applied) or the accessory has at least one of the
/// selected tags (OR semantics: more selected tags broadens results,
/// it doesn't narrow them).
bool matchesTagFilter(Accessory accessory, Set<String> activeFilter) {
  return activeFilter.isEmpty ||
      accessory.tags.any((tag) => activeFilter.contains(tag));
}
```

In `lib/accessory/accessory_registry.dart`, add alongside the existing `accessories` getter (around line 51):

```dart
  /// A list of the user's accessories.
  UnmodifiableListView<Accessory> get accessories =>
      UnmodifiableListView(_accessories);

  /// Every tag currently used by at least one accessory, for autocomplete
  /// suggestions and the tag management screen. Derived, not stored -
  /// there's no tag that exists independently of the accessories using it.
  Set<String> get allTags =>
      accessories.expand((accessory) => accessory.tags).toSet();

  /// Tags currently selected to filter accessory views by. Empty means no
  /// filter - every accessory matches. Session-only (not persisted).
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/accessory/accessory_list_grouping_test.dart test/accessory/accessory_registry_test.dart`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `flutter test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/accessory/accessory_registry.dart lib/accessory/accessory_list.dart \
  test/accessory/accessory_registry_test.dart test/accessory/accessory_list_grouping_test.dart
git commit -m "feat: add tag registry state and the tag filter predicate"
```

---

### Task 3: Tag input widget

**Files:**
- Create: `lib/item_management/accessory_tags_input.dart`
- Modify: `lib/item_management/item_creation.dart`
- Modify: `lib/accessory/accessory_detail.dart`
- Test: `test/item_management/accessory_tags_input_test.dart` (new)

**Interfaces:**
- Consumes: `AccessoryRegistry.allTags` (Task 2).
- Produces: `class AccessoryTagsInput extends StatefulWidget` with `{required List<String> initialTags, required ValueChanged<List<String>> changeListener}`; internal pure helpers `tagsAfterAdding`/`tagsAfterRemoving` (top-level in the same file, exported for the test above - not consumed by any other task).

This task's UI wiring (chip rendering, the `Autocomplete` popup, `TextField` interaction) is not covered by an automated widget test - this codebase has exactly one existing widget test in its entire suite (`test/map/map_cluster_widget_test.dart`, written specifically as a regression test for a real crash), and every other UI feature this session has relied on manual on-device verification instead of new widget-test infrastructure. This task follows that established convention: the *logic* (which tags end up in the list after an add/remove) is extracted into pure, directly-tested functions; the *rendering* is manually verified (see the plan's final Manual Verification section).

- [ ] **Step 1: Write the failing tests**

Create `test/item_management/accessory_tags_input_test.dart`:

```dart
import 'package:macless_haystack/item_management/accessory_tags_input.dart';
import 'package:test/test.dart';

void main() {
  group('tagsAfterAdding', () {
    test('adds a new tag', () {
      expect(tagsAfterAdding(['Keys'], 'Car'), ['Keys', 'Car']);
    });

    test('trims surrounding whitespace before adding', () {
      expect(tagsAfterAdding([], '  Car  '), ['Car']);
    });

    test('does not add an empty or whitespace-only tag', () {
      expect(tagsAfterAdding(['Keys'], ''), ['Keys']);
      expect(tagsAfterAdding(['Keys'], '   '), ['Keys']);
    });

    test('does not add a tag that already exists (exact match)', () {
      expect(tagsAfterAdding(['Keys'], 'Keys'), ['Keys']);
    });

    test('is case-sensitive - "car" and "Car" are different tags', () {
      expect(tagsAfterAdding(['Car'], 'car'), ['Car', 'car']);
    });
  });

  group('tagsAfterRemoving', () {
    test('removes the given tag', () {
      expect(tagsAfterRemoving(['Keys', 'Car'], 'Keys'), ['Car']);
    });

    test('is a no-op if the tag is not present', () {
      expect(tagsAfterRemoving(['Keys'], 'Car'), ['Keys']);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/item_management/accessory_tags_input_test.dart`
Expected: FAIL - the file doesn't exist yet.

- [ ] **Step 3: Implement the widget**

Create `lib/item_management/accessory_tags_input.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';

/// [tags] with [newTag] appended, trimmed, unless it's empty/whitespace-only
/// or already present (exact, case-sensitive match).
List<String> tagsAfterAdding(List<String> tags, String newTag) {
  var trimmed = newTag.trim();
  if (trimmed.isEmpty || tags.contains(trimmed)) {
    return tags;
  }
  return [...tags, trimmed];
}

/// [tags] with [tagToRemove] removed, if present.
List<String> tagsAfterRemoving(List<String> tags, String tagToRemove) {
  return tags.where((tag) => tag != tagToRemove).toList();
}

/// Lets the user add/remove free-form tags on an accessory, with
/// autocomplete suggestions drawn from every tag already used elsewhere.
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

class _AccessoryTagsInputState extends State<AccessoryTagsInput> {
  late List<String> _tags;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tags = widget.initialTags;
  }

  void _addTag(String value) {
    var updated = tagsAfterAdding(_tags, value);
    setState(() {
      _tags = updated;
      _controller.clear();
    });
    widget.changeListener(updated);
  }

  void _removeTag(String tag) {
    var updated = tagsAfterRemoving(_tags, tag);
    setState(() {
      _tags = updated;
    });
    widget.changeListener(updated);
  }

  @override
  Widget build(BuildContext context) {
    var knownTags = Provider.of<AccessoryRegistry>(context, listen: false).allTags;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_tags.isNotEmpty)
            Wrap(
              spacing: 4,
              children: _tags
                  .map((tag) => Chip(
                        label: Text(tag),
                        onDeleted: () => _removeTag(tag),
                      ))
                  .toList(),
            ),
          Autocomplete<String>(
            optionsBuilder: (textEditingValue) {
              if (textEditingValue.text.isEmpty) {
                return const Iterable<String>.empty();
              }
              return knownTags.where((tag) => tag
                  .toLowerCase()
                  .contains(textEditingValue.text.toLowerCase()));
            },
            onSelected: _addTag,
            fieldViewBuilder:
                (context, fieldController, focusNode, onFieldSubmitted) {
              return TextField(
                controller: fieldController,
                focusNode: focusNode,
                decoration: const InputDecoration(labelText: 'Add tag'),
                onSubmitted: (value) {
                  _addTag(value);
                  onFieldSubmitted();
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/item_management/accessory_tags_input_test.dart`
Expected: PASS (9 tests)

- [ ] **Step 5: Wire into item_creation.dart**

In `lib/item_management/item_creation.dart`, add the import:

```dart
import 'package:macless_haystack/item_management/accessory_tags_input.dart';
```

Add the widget to the `Column`, after `AccessoryColorInput`:

```dart
              AccessoryTagsInput(
                initialTags: newAccessory.tags,
                changeListener: (tags) {
                  setState(() {
                    newAccessory.tags = tags;
                  });
                },
              ),
```

- [ ] **Step 6: Wire into accessory_detail.dart**

In `lib/accessory/accessory_detail.dart`, add the import:

```dart
import 'package:macless_haystack/item_management/accessory_tags_input.dart';
```

Add the widget after `AccessoryNameInput`, following the exact persist-immediately pattern the adjacent `isActive` `SwitchListTile` already uses:

```dart
              AccessoryTagsInput(
                initialTags: newAccessory.tags,
                changeListener: (tags) {
                  setState(() {
                    newAccessory.tags = tags;
                  });
                  var accessoryRegistry =
                      Provider.of<AccessoryRegistry>(context, listen: false);
                  var updatedAccessory = widget.accessory.clone();
                  updatedAccessory.tags = tags;
                  accessoryRegistry.editAccessory(
                      widget.accessory, updatedAccessory);
                },
              ),
```

(`newAccessory` is this screen's existing local mutable copy of `widget.accessory` used for in-progress edits - the same variable name the adjacent `AccessoryNameInput`/`isActive` handlers already use.)

- [ ] **Step 7: Run the full suite**

Run: `flutter test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add lib/item_management/accessory_tags_input.dart lib/item_management/item_creation.dart \
  lib/accessory/accessory_detail.dart test/item_management/accessory_tags_input_test.dart
git commit -m "feat: add tag input widget to accessory creation and editing"
```

---

### Task 4: Tag badge display

**Files:**
- Modify: `lib/item_management/item_management.dart`
- Modify: `lib/accessory/accessory_list_item.dart`

**Interfaces:**
- Consumes: `Accessory.tags` (Task 1).

No dedicated automated test for this task, for the same reason given in Task 3 - this is pure display composition (a `Wrap` of read-only `Chip`s), and this codebase's established convention is manual on-device verification for UI rendering, not new widget-test infrastructure. The full suite regression run is this task's test evidence.

- [ ] **Step 1: Add tag chips to `KeyManagement`'s rows**

In `lib/item_management/item_management.dart`, change each row's `subtitle` from a single `Text` to a `Column` that adds a chip row when the accessory has tags:

```dart
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
                                      style:
                                          Theme.of(context).textTheme.labelSmall),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ))
                            .toList(),
                      ),
                  ],
                ),
```

- [ ] **Step 2: Add tag chips to `accessory_list_item.dart`'s non-compact rows**

In `lib/accessory/accessory_list_item.dart`, change the non-compact `subtitle` (currently a single `Text`) to include tag chips below it when present:

```dart
              subtitle: isCompact
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          locationString + dateString,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (widget.accessory.tags.isNotEmpty)
                          Wrap(
                            spacing: 4,
                            children: widget.accessory.tags
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
```

Compact mode (`isCompact ? _buildCompactTitle(...) : ...` and the `trailing`/`title` branches) is unchanged - tags never appear there.

- [ ] **Step 3: Run the full suite**

Run: `flutter test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/item_management/item_management.dart lib/accessory/accessory_list_item.dart
git commit -m "feat: display tag badges on accessory rows"
```

---

### Task 5: Filter chip row in the Accessories tab

**Files:**
- Modify: `lib/item_management/item_management.dart`

**Interfaces:**
- Consumes: `AccessoryRegistry.allTags`, `AccessoryRegistry.activeTagFilter`, `AccessoryRegistry.toggleTagFilter` (Task 2), `matchesTagFilter` (Task 2).

No dedicated automated test - the filtering logic itself (`matchesTagFilter`) is already covered by Task 2's tests; this task is UI wiring only (a `FilterChip` row and a conditional empty-state message), following the same manual-verification convention as Tasks 3-4.

- [ ] **Step 1: Filter the list and add the chip row**

In `lib/item_management/item_management.dart`, change the `Consumer<AccessoryRegistry>` builder:

```dart
      builder: (context, accessoryRegistry, child) {
        var allAccessories = accessoryRegistry.accessories;
        var accessories = allAccessories
            .where((a) => matchesTagFilter(a, accessoryRegistry.activeTagFilter))
            .toList();

        if (allAccessories.isEmpty) {
          if (!accessoryRegistry.initialLoadFinished) {
            return const LoadingSpinner();
          }
          return const NoAccessoriesPlaceholder();
        }

        var filterRow = accessoryRegistry.allTags.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Wrap(
                  spacing: 8,
                  children: accessoryRegistry.allTags
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
```

Add the import needed for `matchesTagFilter`:

```dart
import 'package:macless_haystack/accessory/accessory_list.dart';
```

This restructures the existing `return Scrollbar(child: ListView(...))` (with Task 4's tag-chip subtitle already applied) to sit inside a `Column`/`Expanded` alongside the new filter row, rather than being the builder's sole return value.

- [ ] **Step 2: Run the full suite**

Run: `flutter test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/item_management/item_management.dart
git commit -m "feat: add tag filter chips to the Accessories tab"
```

---

### Task 6: Map marker tag filtering

**Files:**
- Modify: `lib/map/map.dart`
- Test: `test/map/map_test.dart`

**Interfaces:**
- Consumes: `matchesTagFilter` (Task 2), `AccessoryRegistry.activeTagFilter` (Task 2).
- Produces: `List<Accessory> tagFilteredAccessories(List<Accessory> accessories, Set<String> activeTagFilter)` - a top-level pure function in `lib/map/map.dart`.

`test/map/map_test.dart` already exists and tests this file's pure functions (e.g. `shouldFitToAccessoryLocations`) directly, without pumping the full `AccessoryMap` widget - `tagFilteredAccessories` joins that same pattern. The actual map-rendering effect (do filtered-out markers really disappear) is manually verified (see the plan's final section) - `test/map/map_cluster_widget_test.dart`'s own doc comment already documents why this file avoids pumping the real `AccessoryMap` widget (it needs `MapTileProviderModel` and a live network `TileLayer`).

- [ ] **Step 1: Write the failing test**

Add to `test/map/map_test.dart` (check its existing imports/fixture style first and match them - it already constructs `Accessory` objects for other tests in this file):

```dart
  group('tagFilteredAccessories', () {
    Accessory withTags(String id, List<String> tags) => Accessory(
        id: id,
        name: 'Test $id',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: [],
        tags: tags);

    test('an empty filter returns every accessory unchanged', () {
      var a = withTags('a', ['Keys']);
      var b = withTags('b', []);

      expect(tagFilteredAccessories([a, b], {}), [a, b]);
    });

    test('keeps only accessories matching the active filter', () {
      var a = withTags('a', ['Keys']);
      var b = withTags('b', ['Car']);

      expect(tagFilteredAccessories([a, b], {'Keys'}), [a]);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/map/map_test.dart`
Expected: FAIL - `tagFilteredAccessories` isn't defined.

- [ ] **Step 3: Implement**

In `lib/map/map.dart`, add near the other top-level pure functions (`shouldFitToAccessoryLocations`, `selectedAccessory`):

```dart
/// [accessories] filtered down to those matching [activeTagFilter] (see
/// [matchesTagFilter] - empty filter keeps everything). Centralizing this
/// one filter step means every function downstream of it
/// (shouldFitToAccessoryLocations, fitToContent, selectedAccessory,
/// accessoryMarkers) needs no changes of its own - they already just
/// operate on whatever accessories list they're handed.
List<Accessory> tagFilteredAccessories(
  List<Accessory> accessories,
  Set<String> activeTagFilter,
) {
  return accessories
      .where((accessory) => matchesTagFilter(accessory, activeTagFilter))
      .toList();
}
```

Add the import for `matchesTagFilter`:

```dart
import 'package:macless_haystack/accessory/accessory_list.dart';
```

Then apply it at the 4 existing places this file reads `accessoryRegistry.accessories` for rendering/camera-fitting. In `initState()`:

```dart
    // Resize map to fit all accessories at initial location
    _hasFittedToAccessories = shouldFitToAccessoryLocations(
      tagFilteredAccessories(
          accessoryRegistry.accessories, accessoryRegistry.activeTagFilter),
      false,
    );
    fitToContent(
        tagFilteredAccessories(
            accessoryRegistry.accessories, accessoryRegistry.activeTagFilter),
        locationModel.here);

    // Fit map if first location is known
    void listener() {
      // Only use the first location, cancel further updates
      cancelLocationUpdates?.call();
      fitToContent(
          tagFilteredAccessories(accessoryRegistry.accessories,
              accessoryRegistry.activeTagFilter),
          locationModel.here);
    }
```

In `build()`:

```dart
      var accessories = tagFilteredAccessories(
          accessoryRegistry.accessories, accessoryRegistry.activeTagFilter);
```

(This one line already feeds `shouldFitToAccessoryLocations`, `fitToContent`, `selectedAccessory`, and - via `_accessoryMarkersFor(accessories)` - the actual marker rendering later in this same build method. No other line in `build()` needs to change.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/map/map_test.dart`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `flutter test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/map/map.dart test/map/map_test.dart
git commit -m "feat: filter map markers by the active tag filter"
```

---

### Task 7: Tag management screen

**Files:**
- Create: `lib/item_management/tag_management.dart`
- Test: `test/item_management/tag_management_test.dart` (new)

**Interfaces:**
- Consumes: `Accessory.tags` (Task 1), `AccessoryRegistry.allTags`/`accessories`/`editAccessory` (Task 2 and pre-existing).
- Produces: `class TagManagementScreen extends StatelessWidget` (no constructor params - reads `AccessoryRegistry` via `Provider`), consumed by Task 8. Pure helpers `accessoriesAfterTagRename`/`accessoriesAfterTagDelete` (top-level in the same file), tested directly here.

- [ ] **Step 1: Write the failing tests**

Create `test/item_management/tag_management_test.dart`:

```dart
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/item_management/tag_management.dart';
import 'package:test/test.dart';

void main() {
  Accessory withTags(String id, List<String> tags) => Accessory(
      id: id,
      name: 'Test $id',
      hashedPublicKey: '',
      datePublished: null,
      hashesWithTS: {},
      locationHistory: [],
      lastBatteryStatus: null,
      additionalKeys: [],
      tags: tags);

  group('accessoriesAfterTagRename', () {
    test('replaces the old tag with the new one on every matching accessory', () {
      var a = withTags('a', ['Keys', 'Car']);
      var b = withTags('b', ['Car']);
      var c = withTags('c', ['Bag']);

      var result = accessoriesAfterTagRename([a, b, c], 'Car', 'Vehicle');

      expect(result.firstWhere((acc) => acc.id == 'a').tags, ['Keys', 'Vehicle']);
      expect(result.firstWhere((acc) => acc.id == 'b').tags, ['Vehicle']);
      expect(result.firstWhere((acc) => acc.id == 'c').tags, ['Bag']);
    });

    test('renaming to a tag the accessory already has collapses to one entry, not a duplicate', () {
      var a = withTags('a', ['Keys', 'Car']);

      var result = accessoriesAfterTagRename([a], 'Car', 'Keys');

      expect(result.single.tags, ['Keys']);
    });

    test('returns only the accessories that actually changed', () {
      var a = withTags('a', ['Keys']);
      var b = withTags('b', ['Car']);

      var result = accessoriesAfterTagRename([a, b], 'Car', 'Vehicle');

      expect(result, hasLength(1));
      expect(result.single.id, 'b');
    });
  });

  group('accessoriesAfterTagDelete', () {
    test('removes the tag from every matching accessory', () {
      var a = withTags('a', ['Keys', 'Car']);
      var b = withTags('b', ['Bag']);

      var result = accessoriesAfterTagDelete([a, b], 'Car');

      expect(result, hasLength(1));
      expect(result.single.id, 'a');
      expect(result.single.tags, ['Keys']);
    });

    test('returns an empty list when no accessory has the tag', () {
      var a = withTags('a', ['Keys']);

      expect(accessoriesAfterTagDelete([a], 'Car'), isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/item_management/tag_management_test.dart`
Expected: FAIL - the file doesn't exist yet.

- [ ] **Step 3: Implement the pure functions and the screen**

Create `lib/item_management/tag_management.dart`:

```dart
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/item_management/tag_management_test.dart`
Expected: PASS (5 tests)

- [ ] **Step 5: Run the full suite**

Run: `flutter test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/item_management/tag_management.dart test/item_management/tag_management_test.dart
git commit -m "feat: add tag management screen (rename/delete across all accessories)"
```

---

### Task 8: Dashboard entry point

**Files:**
- Modify: `lib/dashboard/dashboard.dart`

**Interfaces:**
- Consumes: `TagManagementScreen` (Task 7).

No dedicated automated test - a single `AppBar` action wiring to a screen push, no new logic. The full suite regression run is this task's test evidence.

- [ ] **Step 1: Add the AppBar action**

In `lib/dashboard/dashboard.dart`, add the import:

```dart
import 'package:macless_haystack/item_management/tag_management.dart';
```

In the shared `AppBar`'s `actions` list, add a new branch for the Accessories tab (index 1), following the existing `if (_selectedIndex == 0)` branch's pattern:

```dart
        appBar: AppBar(
          title: Text(_tabs[_selectedIndex]['label'] as String),
          actions: <Widget>[
            if (_selectedIndex == 0)
              PopupMenuButton<void>(
                tooltip: 'More',
                itemBuilder: (context) => [
                  PopupMenuItem<void>(
                    onTap: () => loadLocationUpdates(null, force: true),
                    child: const Text('Force fetch from Apple'),
                  ),
                ],
              ),
            if (_selectedIndex == 1)
              IconButton(
                tooltip: 'Manage tags',
                icon: const Icon(Icons.label_outline),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const TagManagementScreen()),
                  );
                },
              ),
            IconButton(
              tooltip: 'Settings',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const PreferencesPage()),
                );
              },
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
```

- [ ] **Step 2: Run the full suite**

Run: `flutter test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/dashboard/dashboard.dart
git commit -m "feat: add a Manage tags entry point to the Accessories tab"
```

---

## Manual verification (user follow-up, not automated here)

This session has no access to a running device from here, so the following must be checked by the user after pulling and rebuilding, the same as prior features this session:

1. Create or edit an accessory, add a few tags via the chip input, confirm autocomplete suggests tags already used on other accessories, confirm removing a chip works, confirm a duplicate/empty tag can't be added.
2. Confirm tag chips render on both the Accessories tab's rows and the map's bottom-sheet list rows (non-compact mode only for the latter - toggle "Compact accessory list" in Settings to check both).
3. On the Accessories tab, toggle a filter chip and confirm the list narrows to matching accessories, that selecting multiple tags broadens the match (OR), and that the "no accessories match" message appears when nothing matches.
4. Confirm the map's markers (and the camera's auto-fit-to-content on launch) also respect the active tag filter.
5. Open "Manage tags" from the Accessories tab's AppBar, rename a tag, and confirm it updates everywhere that tag was used (including collapsing correctly if the rename target already existed on some accessory); delete a tag and confirm it's removed everywhere.
