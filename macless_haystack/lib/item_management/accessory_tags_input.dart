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
