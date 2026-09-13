import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:macless_haystack/item_management/item_creation.dart';
import 'package:macless_haystack/item_management/item_file_import.dart';
import 'package:macless_haystack/item_management/item_import.dart';

class NewKeyAction extends StatelessWidget {
  /// If the action button is small.
  final bool mini;

  /// Displays a floating button used to access the accessory creation menu.
  ///
  /// A new accessory can be created or an existing one imported manually.
  const NewKeyAction({
    super.key,
    this.mini = false,
  });

  /// Display a bottom sheet with creation options.
  void showCreationSheet(BuildContext context) {
    showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (BuildContext context) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    'Add accessory',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ListTile(
                  title: const Text('Import Accessory'),
                  leading: const Icon(Icons.import_export),
                  onTap: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const AccessoryImport()),
                    );
                  },
                ),
                ListTile(
                  title: const Text('Import from JSON File'),
                  leading: const Icon(Icons.description),
                  onTap: () async {
                    PlatformFile? result = await FilePicker.pickFile(
                      type: FileType.custom,
                      allowedExtensions: ['json'],
                      dialogTitle: 'Select accessory configuration',
                    );

                    if (result != null) {
                      Uint8List uploadfile;
                      try {
                        uploadfile = await result.readAsBytes();
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Could not read the selected '
                                  'file.'),
                            ),
                          );
                        }
                        return;
                      }
                      if (context.mounted) {
                        Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  ItemFileImport(bytes: uploadfile),
                            ));
                      }
                    }
                  },
                ),
                ListTile(
                  title: const Text('Create New Accessory'),
                  leading: const Icon(Icons.add),
                  onTap: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const AccessoryGeneration()),
                    );
                  },
                ),
              ],
            ),
          );
        });
  }

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      mini: mini,
      heroTag: null,
      onPressed: () {
        showCreationSheet(context);
      },
      tooltip: 'Create',
      child: const Icon(Icons.add),
    );
  }
}
