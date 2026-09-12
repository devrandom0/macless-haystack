import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_color_selector.dart';
import 'package:macless_haystack/accessory/accessory_icon.dart';
import 'package:macless_haystack/accessory/accessory_icon_selector.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/history/archive_settings_validation.dart';
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
  final _archiveSettingsFormKey = GlobalKey<FormState>();
  bool _archivingLoading = true;
  bool _archivingEnabled = false;
  // Guards against overlapping archive requests (e.g. rapidly re-toggling
  // the switch): while true, the switch and the settings form are disabled,
  // so at most one _setArchiving/_disableArchivingBestEffort/
  // _updateArchiveSettings call (including its own follow-up reload) is
  // ever in flight at a time.
  bool _archivingUpdating = false;
  final _pollIntervalController = TextEditingController();
  final _retentionDaysController = TextEditingController();

  @override
  void initState() {
    // Initialize changed accessory with existing accessory properties.
    newAccessory = widget.accessory.clone();
    super.initState();
    _loadArchivingStatus();
  }

  @override
  void dispose() {
    _pollIntervalController.dispose();
    _retentionDaysController.dispose();
    super.dispose();
  }

  /// Loads the current archiving status from the server. If
  /// [onlyIfBlank] is true, the interval/retention fields are only
  /// populated when currently empty, so this never overwrites a value
  /// the user may already be editing.
  Future<void> _loadArchivingStatus({bool onlyIfBlank = false}) async {
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
      ArchivedDeviceStatus? enabledDevice;
      for (var d in devices) {
        if (relevantKeys.contains(d.hashedPublicKey) && d.enabled) {
          enabledDevice = d;
          break;
        }
      }
      if (mounted) {
        setState(() {
          _archivingEnabled = enabledDevice != null;
          _archivingLoading = false;
          if (enabledDevice != null) {
            if (!onlyIfBlank || _pollIntervalController.text.isEmpty) {
              _pollIntervalController.text =
                  enabledDevice.pollIntervalHours.toString();
            }
            if (!onlyIfBlank || _retentionDaysController.text.isEmpty) {
              _retentionDaysController.text =
                  enabledDevice.retentionDays.toString();
            }
          }
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

  /// Builds the [HistoryDeviceEntry] list for this accessory's main key and
  /// any additional keys, shared by every place that pushes an archiving
  /// state (or setting) to the server for this accessory.
  Future<List<HistoryDeviceEntry>> _buildDeviceEntries(bool enabled,
      {int? pollIntervalHours, int? retentionDays}) async {
    var accessory = widget.accessory;
    var additionalPrivateKeys = await accessory.getAdditionalPrivateKeys();
    return [
      HistoryDeviceEntry(
        hashedPublicKey: accessory.hashedPublicKey,
        privateKey: await accessory.getPrivateKey(),
        name: accessory.name,
        accessoryId: accessory.id,
        enabled: enabled,
        pollIntervalHours: pollIntervalHours,
        retentionDays: retentionDays,
      ),
      for (var i = 0; i < accessory.additionalKeys.length; i++)
        HistoryDeviceEntry(
          hashedPublicKey: accessory.additionalKeys[i],
          privateKey: additionalPrivateKeys[i],
          name: '${accessory.name} (extra key)',
          accessoryId: accessory.id,
          enabled: enabled,
          pollIntervalHours: pollIntervalHours,
          retentionDays: retentionDays,
        ),
    ];
  }

  Future<void> _setArchiving(bool enabled) async {
    var previous = _archivingEnabled;
    setState(() {
      _archivingEnabled = enabled;
      _archivingUpdating = true;
    });
    try {
      var url = Settings.getValue<String>(endpointUrl,
          defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;

      var devices = await _buildDeviceEntries(enabled);

      await HistoryArchiveService.setDevicesArchiving(
          url, user, pass, devices);

      // Refresh the interval/retention fields from the server so, when
      // enabling, they show the server-applied values (its default for a
      // brand-new device, or the device's preserved existing value)
      // instead of sitting empty until the screen is reopened. Only fill
      // in blank fields, in case the user started typing while this was
      // in flight.
      if (enabled) {
        await _loadArchivingStatus(onlyIfBlank: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _archivingEnabled = previous;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update server-side archiving: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _archivingUpdating = false;
        });
      }
    }
  }

  /// Best-effort disabling of server-side archiving when this accessory is
  /// deactivated. Failures are swallowed - this is a secondary side effect
  /// of the Is Active toggle, which must keep working even if this fails.
  Future<void> _disableArchivingBestEffort() async {
    if (mounted) {
      setState(() {
        _archivingUpdating = true;
      });
    }
    try {
      var url = Settings.getValue<String>(endpointUrl,
          defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;

      var devices = await _buildDeviceEntries(false);
      await HistoryArchiveService.setDevicesArchiving(
          url, user, pass, devices);
      if (mounted) {
        setState(() {
          _archivingEnabled = false;
        });
      }
    } catch (e) {
      // Best-effort: ignore failures, the Is Active toggle already
      // committed locally and must not be blocked by this.
    } finally {
      if (mounted) {
        setState(() {
          _archivingUpdating = false;
        });
      }
    }
  }

  Future<void> _updateArchiveSettings() async {
    if (_archiveSettingsFormKey.currentState?.validate() != true) {
      return;
    }
    setState(() {
      _archivingUpdating = true;
    });
    try {
      var url = Settings.getValue<String>(endpointUrl,
          defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;

      var pollIntervalHours = int.parse(_pollIntervalController.text);
      var retentionDays = int.parse(_retentionDaysController.text);

      var devices = await _buildDeviceEntries(true,
          pollIntervalHours: pollIntervalHours, retentionDays: retentionDays);
      await HistoryArchiveService.setDevicesArchiving(
          url, user, pass, devices);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Archive settings updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update archive settings: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _archivingUpdating = false;
        });
      }
    }
  }

  Widget _buildArchiveSettingsForm() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Form(
        key: _archiveSettingsFormKey,
        child: Column(
          children: [
            TextFormField(
              controller: _pollIntervalController,
              decoration:
                  const InputDecoration(labelText: 'Poll interval (hours)'),
              keyboardType: TextInputType.number,
              validator: validatePollIntervalHours,
            ),
            TextFormField(
              controller: _retentionDaysController,
              decoration:
                  const InputDecoration(labelText: 'Retention (days)'),
              keyboardType: TextInputType.number,
              validator: validateRetentionDays,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _archivingUpdating ? null : _updateArchiveSettings,
                child: const Text('Update'),
              ),
            ),
          ],
        ),
      ),
    );
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
                  // Persist only the active flag, from the accessory as
                  // currently saved - not from newAccessory, which may hold
                  // other unsaved, unvalidated edits from this same form.
                  var accessoryRegistry =
                      Provider.of<AccessoryRegistry>(context, listen: false);
                  var updatedAccessory = widget.accessory.clone();
                  updatedAccessory.isActive = checked;
                  accessoryRegistry.editAccessory(
                      widget.accessory, updatedAccessory);

                  if (!checked && _archivingEnabled) {
                    _disableArchivingBestEffort();
                  }
                },
              ),
              SwitchListTile(
                value: _archivingEnabled,
                title: const Text('Archive location history on server'),
                subtitle:
                    _archivingLoading ? const Text('Loading status…') : null,
                onChanged: (_archivingLoading || _archivingUpdating)
                    ? null
                    : _setArchiving,
              ),
              if (_archivingEnabled) _buildArchiveSettingsForm(),
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
