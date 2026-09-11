import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_color_selector.dart';
import 'package:macless_haystack/accessory/accessory_icon.dart';
import 'package:macless_haystack/accessory/accessory_icon_selector.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/history/history_archive_service.dart';
import 'package:macless_haystack/item_management/accessory_name_input.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

class AccessoryDetail extends StatefulWidget {
  final Accessory accessory;

  /// A page displaying the editable information of a specific [accessory].
  ///
  /// This shows the editable information of a specific [accessory] and
  /// allows the user to edit them.
  const AccessoryDetail({
    super.key,
    required this.accessory,
  });

  @override
  State<StatefulWidget> createState() {
    return _AccessoryDetailState();
  }

// @override
// _AccessoryDetailState createState() => _AccessoryDetailState();
}

class _AccessoryDetailState extends State<AccessoryDetail> {
  // An accessory storing the changed values.
  late Accessory newAccessory;
  final _formKey = GlobalKey<FormState>();
  bool _archivingLoading = true;
  bool _archivingEnabled = false;

  @override
  void initState() {
    // Initialize changed accessory with existing accessory properties.
    newAccessory = widget.accessory.clone();
    super.initState();
    _loadArchivingStatus();
  }

  Future<void> _loadArchivingStatus() async {
    try {
      var url = Settings.getValue<String>(endpointUrl,
          defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
      var devices = await HistoryArchiveService.getArchivedDevices(
          url, user, pass);
      var relevantKeys = {
        widget.accessory.hashedPublicKey,
        ...widget.accessory.additionalKeys
      };
      var enabled = devices
          .any((d) => relevantKeys.contains(d.hashedPublicKey) && d.enabled);
      if (mounted) {
        setState(() {
          _archivingEnabled = enabled;
          _archivingLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _archivingLoading = false;
        });
      }
    }
  }

  Future<void> _setArchiving(bool enabled) async {
    var previous = _archivingEnabled;
    setState(() {
      _archivingEnabled = enabled;
    });
    try {
      var url = Settings.getValue<String>(endpointUrl,
          defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;

      var accessory = widget.accessory;
      var additionalPrivateKeys = await accessory.getAdditionalPrivateKeys();
      List<HistoryDeviceEntry> devices = [
        HistoryDeviceEntry(
          hashedPublicKey: accessory.hashedPublicKey,
          privateKey: await accessory.getPrivateKey(),
          name: accessory.name,
          accessoryId: accessory.id,
          enabled: enabled,
        ),
        for (var i = 0; i < accessory.additionalKeys.length; i++)
          HistoryDeviceEntry(
            hashedPublicKey: accessory.additionalKeys[i],
            privateKey: additionalPrivateKeys[i],
            name: '${accessory.name} (extra key)',
            accessoryId: accessory.id,
            enabled: enabled,
          ),
      ];

      await HistoryArchiveService.setDevicesArchiving(
          url, user, pass, devices);
    } catch (e) {
      if (mounted) {
        setState(() {
          _archivingEnabled = previous;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update server-side archiving: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.accessory.name),
      ),
      body: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Center(
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: AccessoryIcon(
                        size: 100,
                        icon: newAccessory.icon,
                        color: newAccessory.color,
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Padding(
                        padding: const EdgeInsets.all(10.0),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Color.fromARGB(255, 200, 200, 200),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            onPressed: () async {
                              // Show icon selection
                              String? selectedIcon =
                                  await AccessoryIconSelector.showIconSelection(
                                      context,
                                      newAccessory.rawIcon,
                                      newAccessory.color);
                              if (selectedIcon != null) {
                                setState(() {
                                  newAccessory.setIcon(selectedIcon);
                                });
                                if (context.mounted) {
                                  // Show color selection only when icon is selected
                                  Color? selectedColor =
                                      await AccessoryColorSelector
                                          .showColorSelection(
                                              context, newAccessory.color);
                                  if (selectedColor != null) {
                                    setState(() {
                                      newAccessory.color = selectedColor;
                                    });
                                  }
                                }
                              }
                            },
                            icon: Icon(
                              Icons.edit,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              AccessoryNameInput(
                initialValue: newAccessory.name,
                onChanged: (value) {
                  setState(() {
                    newAccessory.name = value;
                  });
                },
              ),
              SwitchListTile(
                value: newAccessory.isActive,
                title: const Text('Is Active'),
                onChanged: (checked) {
                  setState(() {
                    newAccessory.isActive = checked;
                  });
                },
              ),
              SwitchListTile(
                value: _archivingEnabled,
                title: const Text('Archive location history on server'),
                subtitle:
                    _archivingLoading ? const Text('Loading status…') : null,
                onChanged: _archivingLoading ? null : _setArchiving,
              ),
              ListTile(
                title: OutlinedButton(
                  onPressed: _formKey.currentState == null ||
                          !_formKey.currentState!.validate()
                      ? null
                      : () {
                          if (_formKey.currentState != null &&
                              _formKey.currentState!.validate()) {
                            // Update accessory with changed values
                            var accessoryRegistry =
                                Provider.of<AccessoryRegistry>(context,
                                    listen: false);
                            accessoryRegistry.editAccessory(
                                widget.accessory, newAccessory);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Changes saved!'),
                              ),
                            );
                          }
                        },
                  child: const Text('Save'),
                ),
              ),
              ListTile(
                title: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () {
                    // Update accessory with changed values
                    var accessoryRegistry =
                        Provider.of<AccessoryRegistry>(context, listen: false);
                    accessoryRegistry.deleteData(widget.accessory);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('All current and historical data deleted'),
                      ),
                    );
                  },
                  child: const Text('Reset Accessory'),
                ),
              ),
              ListTile(
                title: ElevatedButton(
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith<Color?>(
                      (Set<WidgetState> states) {
                        return Theme.of(context).colorScheme.error;
                      },
                    ),
                  ),
                  child: const Text(
                    'Delete Accessory',
                    style: TextStyle(color: Colors.white),
                  ),
                  onPressed: () {
                    // Delete accessory
                    var accessoryRegistry =
                        Provider.of<AccessoryRegistry>(context, listen: false);
                    accessoryRegistry.removeAccessory(widget.accessory);
                    Navigator.pop(context);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
