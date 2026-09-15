import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_dto.dart';
import 'package:macless_haystack/accessory/accessory_icon_model.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/findMy/find_my_controller.dart';
import 'package:macless_haystack/item_management/loading_spinner.dart';
import 'package:macless_haystack/widgets/app_error_state.dart';

class ItemFileImport extends StatefulWidget {
  /// The contents of each file to import from.
  final List<Uint8List> fileBytesList;

  /// Lets the user select which accessories to import from one or more
  /// files.
  ///
  /// Displays the accessories contained across all the import files,
  /// combined into a single list. The user can then select the accessories
  /// to import.
  const ItemFileImport({
    super.key,
    required this.fileBytesList,
  });

  @override
  State<StatefulWidget> createState() {
    return _ItemFileImportState();
  }
}

class _ItemFileImportState extends State<ItemFileImport> {
  /// The accessory information stored in the file
  List<AccessoryDTO>? accessories;

  /// Stores which accessories are selected.
  List<bool>? selected;

  /// Stores which accessory details are expanded
  List<bool>? expanded;

  /// Flag if the passed file can not be imported.
  bool hasError = false;

  /// Stores the reason for the error condition.
  String? errorText;

  @override
  void initState() {
    super.initState();

    _initStateAsync(widget.fileBytesList);
  }

  void _initStateAsync(List<Uint8List> fileBytesList) async {
    // Parse the JSON files and read all contained accessories
    try {
      var accessoryDTOs = await _parseAccessories(fileBytesList);

      setState(() {
        accessories = accessoryDTOs;
        selected = accessoryDTOs.map((_) => true).toList();
        expanded = accessoryDTOs.map((_) => false).toList();
      });
    } catch (e) {
      setState(() {
        hasError = true;
        errorText = fileBytesList.length == 1
            ? 'Could not parse JSON file. Please check if the file is formatted correctly.'
            : 'Could not parse one of the selected JSON files. Please check '
                'if all files are formatted correctly.';
      });
    }
  }

  /// Parse the JSON encoded accessories from each file's [fileBytesList],
  /// combined into a single list.
  Future<List<AccessoryDTO>> _parseAccessories(
      List<Uint8List> fileBytesList) async {
    var accessoryDTOs = <AccessoryDTO>[];
    for (var bytes in fileBytesList) {
      String encodedContent = utf8.decode(bytes);
      List<dynamic> content = jsonDecode(encodedContent);
      accessoryDTOs.addAll(content.map((json) => AccessoryDTO.fromJson(json)));
    }

    return accessoryDTOs;
  }

  /// Whether at least one accessory is currently checked for import.
  bool get _hasSelection => selected?.any((s) => s) ?? false;

  /// Import the selected accessories.
  Future<void> _importSelectedAccessories() async {
    if (accessories == null) {
      return; // File not parsed. Do nothing.
    }

    var registry = Provider.of<AccessoryRegistry>(context, listen: false);

    List<Future<bool>> imports = [];
    for (var i = 0; i < accessories!.length; i++) {
      var accessoryDTO = accessories![i];
      var shouldImport = selected?[i] ?? false;

      if (shouldImport) {
        imports.add(_importAccessory(registry, accessoryDTO));
      }
    }

    var results = await Future.wait(imports);
    var nrOfImports = results.where((succeeded) => succeeded).length;
    if (nrOfImports > 0) {
      var snackbar = SnackBar(
        content: Text(
            'Successfully imported $nrOfImports ${nrOfImports == 1 ? 'accessory' : 'accessories'}.'),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(snackbar);
      }
    }
  }

  /// Import a specific [accessory] by converting the DTO to the internal
  /// representation. Returns whether the import succeeded - a bad key in
  /// one accessory must not silently claim success or take the whole batch
  /// down with it.
  Future<bool> _importAccessory(
      AccessoryRegistry registry, AccessoryDTO accessoryDTO) async {
    try {
      Color color = Colors.grey;
      if (accessoryDTO.colorComponents.length == 4) {
        var colors = accessoryDTO.colorComponents;
        int red = (colors[0] * 255).round();
        int green = (colors[1] * 255).round();
        int blue = (colors[2] * 255).round();
        double opacity = colors[3];
        color = Color.fromRGBO(red, green, blue, opacity);
      }

      String icon = 'mappin';
      if (AccessoryIconModel.icons.contains(accessoryDTO.icon)) {
        icon = accessoryDTO.icon;
      }

      List<String> additionalPublicKeys = await Stream.fromIterable(
              accessoryDTO.additionalKeys as List)
          .asyncMap((addPrivKey) => FindMyController.importKeyPair(addPrivKey))
          .map((event) => event.hashedPublicKey)
          .toList();

      var keyPair =
          await FindMyController.importKeyPair(accessoryDTO.privateKey);

      Accessory newAccessory = Accessory(
          datePublished: DateTime(1970),
          hashedPublicKey: keyPair.hashedPublicKey,
          id: accessoryDTO.id.toString(),
          name: accessoryDTO.name,
          color: color,
          icon: icon,
          isActive: accessoryDTO.isActive,
          lastLocation: null,
          hashesWithTS: {},
          locationHistory: [],
          lastBatteryStatus: null,
          additionalKeys: additionalPublicKeys);

      registry.addAccessory(newAccessory);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (hasError) {
      return _buildScaffold(AppErrorState(
        title: 'An error occurred',
        message: errorText ?? 'An unknown error occurred. Please try again.',
        actionLabel: 'Go back',
        // This screen replaced the file-picker sheet in the nav stack
        // (pushReplacement), so popping lands on the dashboard, not back
        // at a picker - "Go back" says what actually happens instead of
        // promising a re-pick this screen can't do on its own.
        onAction: () => Navigator.pop(context),
      ));
    }

    if (accessories == null) {
      return _buildScaffold(const LoadingSpinner());
    }

    return _buildScaffold(
      SingleChildScrollView(
        child: ExpansionPanelList(
          expansionCallback: (int index, bool isExpanded) {
            setState(() {
              expanded?[index] = !isExpanded;
            });
          },
          children: accessories
                  ?.asMap()
                  .map((idx, accessory) => MapEntry(
                      idx,
                      ExpansionPanel(
                        headerBuilder:
                            (BuildContext context, bool isExpanded) => ListTile(
                          leading: Checkbox(
                              value: selected?[idx] ?? false,
                              onChanged: (newState) {
                                if (newState != null) {
                                  setState(() {
                                    selected?[idx] = newState;
                                  });
                                }
                              }),
                          title: Text(accessory.name),
                        ),
                        body: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24.0, vertical: 8.0),
                          child: Column(
                            children: [
                              _buildProperty('ID', accessory.id.toString()),
                              _buildProperty('Name', accessory.name),
                              _buildProperty('Color',
                                  accessory.colorComponents.toString()),
                              _buildProperty('Icon', accessory.icon),
                              _buildProperty('Private Key',
                                  _maskPrivateKey(accessory.privateKey)),
                              _buildProperty(
                                  'Active', accessory.isActive.toString()),
                              _buildProperty(
                                  'Additional Keys',
                                  accessory.additionalKeys?.length.toString() ??
                                      '0'),
                            ],
                          ),
                        ),
                        isExpanded: expanded?[idx] ?? false,
                      )))
                  .values
                  .toList() ??
              [],
        ),
      ),
    );
  }

  /// Masks the middle of [privateKey] for display, keeping the first and
  /// last 4 characters visible. Falls back to masking the whole string when
  /// it's too short for that split - a real private key is always well
  /// over 8 characters, so this only matters for a malformed/placeholder
  /// value, which shouldn't crash the review screen.
  String _maskPrivateKey(String privateKey) {
    if (privateKey.length <= 8) {
      return '*' * privateKey.length;
    }
    return privateKey.replaceRange(
      4,
      privateKey.length - 4,
      '*' * (privateKey.length - 8),
    );
  }

  /// Display a key-value property.
  Widget _buildProperty(String key, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$key: ',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Flexible(child: Text(value)),
      ],
    );
  }

  /// Surround the [body] widget with a [Scaffold] widget.
  Widget _buildScaffold(Widget body) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select accessories'),
        actions: [
          if (selected != null)
            IconButton(
              tooltip: _hasSelection ? 'Select none' : 'Select all',
              icon: Icon(_hasSelection
                  ? Icons.deselect
                  : Icons.select_all),
              onPressed: () {
                setState(() {
                  var selectAll = !_hasSelection;
                  selected = selected!.map((_) => selectAll).toList();
                });
              },
            ),
          TextButton(
            onPressed: accessories != null && _hasSelection
                ? () async {
                    await _importSelectedAccessories();
                    if (mounted) {
                      Navigator.of(context, rootNavigator: true).pop();
                    }
                  }
                : null,
            child: const Text('Import'),
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}
