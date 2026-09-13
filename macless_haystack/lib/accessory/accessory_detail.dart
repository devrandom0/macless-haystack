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
import 'package:macless_haystack/item_management/item_export.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

/// Shows a Cancel/confirm dialog for a destructive action, returning true
/// only if the user picked [confirmLabel].
Future<bool> confirmDestructiveAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

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
  // Disables the archive switch/Update button while an operation started
  // from one of those two controls is in flight, so a user can't fire a
  // second overlapping request from them. Deliberately NOT set by
  // _disableArchivingBestEffort, which is triggered by the separate Is
  // Active toggle and must never visibly disable other controls while its
  // best-effort network call is in flight (or hung).
  bool _archivingUpdating = false;
  // Every operation that can eventually apply a fetched/computed archiving
  // state captures the current value on entry and only calls setState if
  // it's still current when it finishes - so an Is Active deactivation
  // (which isn't blocked by _archivingUpdating and can complete out of
  // order) can't have its result overwritten by an older, slower operation
  // that was already in flight when it started.
  int _archivingGeneration = 0;
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
  ///
  /// [generation] lets a caller that already claimed a generation (e.g.
  /// _setArchiving, before its own await) pass it through, so this load
  /// is treated as part of that same operation rather than a new one -
  /// if anything else starts in the meantime, both become stale together.
  Future<void> _loadArchivingStatus({bool onlyIfBlank = false, int? generation}) async {
    var myGeneration = generation ?? ++_archivingGeneration;
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
          _archivingLoading = false;
          // A newer operation (e.g. Is Active deactivating this accessory)
          // has already superseded this load - only the loading flag above
          // still applies, the fetched status itself is stale.
          if (myGeneration != _archivingGeneration) {
            return;
          }
          _archivingEnabled = enabledDevice != null;
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
    var myGeneration = ++_archivingGeneration;
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
      // in flight. Passing myGeneration ties this load to the same
      // operation, so it's skipped if Is Active deactivated in the meantime.
      if (enabled) {
        await _loadArchivingStatus(onlyIfBlank: true, generation: myGeneration);
      }
    } catch (e) {
      if (mounted && myGeneration == _archivingGeneration) {
        setState(() {
          _archivingEnabled = previous;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update endpoint archiving: $e')),
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
  /// of the Is Active toggle, which must keep working even if this fails,
  /// so it deliberately never sets _archivingUpdating (which would visibly
  /// disable the archive switch/Update button for as long as this hangs).
  Future<void> _disableArchivingBestEffort() async {
    var myGeneration = ++_archivingGeneration;
    try {
      var url = Settings.getValue<String>(endpointUrl,
          defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;

      var devices = await _buildDeviceEntries(false);
      await HistoryArchiveService.setDevicesArchiving(
          url, user, pass, devices);
      if (mounted && myGeneration == _archivingGeneration) {
        setState(() {
          _archivingEnabled = false;
        });
      }
    } catch (e) {
      // Best-effort: ignore failures, the Is Active toggle already
      // committed locally and must not be blocked by this.
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _archiveSettingsFormKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _pollIntervalController,
                  decoration: const InputDecoration(
                      labelText: 'Poll interval (hours)'),
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
                    onPressed:
                        _archivingUpdating ? null : _updateArchiveSettings,
                    child: const Text('Update'),
                  ),
                ),
              ],
            ),
          ),
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
          autovalidateMode: AutovalidateMode.onUserInteraction,
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
                          decoration: BoxDecoration(
                            // Pairs with the edit icon's colorScheme.primary; the
                            // previous hardcoded grey left it invisible in dark theme.
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: 'Change icon and color',
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
                              color: Theme.of(context).colorScheme.primary,
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
                title: const Text('Active'),
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
                title: const Text('Archive location history on endpoint'),
                subtitle: Text(
                  _archivingLoading
                      ? 'Loading status…'
                      : _archivingUpdating
                          ? 'Updating…'
                          : 'Sends a request to the endpoint - unlike the '
                              'other settings on this page, this can fail',
                ),
                secondary: _archivingUpdating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onChanged: (_archivingLoading || _archivingUpdating)
                    ? null
                    : _setArchiving,
              ),
              if (_archivingEnabled) _buildArchiveSettingsForm(),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      onPressed: () {
                        // A Form's own validate() is re-run on every
                        // keystroke via autovalidateMode, so Save can just
                        // stay enabled and check the live result on press
                        // instead of disabling itself before the form has
                        // even been touched once.
                        if (_formKey.currentState?.validate() ?? false) {
                          var accessoryRegistry = Provider.of<AccessoryRegistry>(
                              context,
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
                    const SizedBox(height: 12),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: () async {
                        var confirmed = await confirmDestructiveAction(
                          context,
                          title: 'Reset "${widget.accessory.name}"?',
                          message:
                              'This permanently deletes its location history, '
                              'last known location, and battery status. The '
                              'accessory itself and its private key are kept.',
                          confirmLabel: 'Reset',
                        );
                        if (!confirmed || !context.mounted) return;
                        var accessoryRegistry = Provider.of<AccessoryRegistry>(
                            context,
                            listen: false);
                        accessoryRegistry.deleteData(widget.accessory);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content:
                                Text('All current and historical data deleted'),
                          ),
                        );
                      },
                      child: const Text('Reset accessory'),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      ),
                      onPressed: () async {
                        var action = await showDialog<String>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title:
                                Text('Delete "${widget.accessory.name}"?'),
                            content: const Text(
                                'This permanently deletes the accessory and '
                                'its private key. Without that key, this '
                                'accessory can never be tracked again - '
                                'export it first if you want to keep it.'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, 'cancel'),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, 'export'),
                                child: const Text('Export key first'),
                              ),
                              TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor:
                                      Theme.of(dialogContext).colorScheme.error,
                                ),
                                onPressed: () =>
                                    Navigator.pop(dialogContext, 'delete'),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (!context.mounted) return;
                        if (action == 'export') {
                          ItemExportMenu(accessory: widget.accessory)
                              .showKeyExportSheet(context, widget.accessory);
                          return;
                        }
                        if (action == 'delete') {
                          var accessoryRegistry = Provider.of<AccessoryRegistry>(
                              context,
                              listen: false);
                          accessoryRegistry.removeAccessory(widget.accessory);
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                      child: const Text('Delete accessory'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
