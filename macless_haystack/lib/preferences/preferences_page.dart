import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/apple_auth/apple_auth_page.dart';
import 'package:macless_haystack/apple_auth/apple_auth_service.dart';
import 'package:macless_haystack/history/archive_settings_validation.dart';
import 'package:macless_haystack/history/history_archive_service.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/preferences/theme_model.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
import 'package:macless_haystack/util/theme_mode.dart';
import 'package:macless_haystack/util/time_format.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Title for the endpoint password field, indicating whether a password is
/// currently stored without ever revealing its value.
String passwordFieldTitle(String storedPassword) {
  return storedPassword.isEmpty
      ? 'Password for endpoint'
      : 'Password for endpoint (set)';
}

/// Resolves what to actually persist after the password edit dialog is
/// submitted with [submittedValue], given whether a password was already
/// set ([hadExistingPassword]).
///
/// The edit field never shows or is pre-filled with the real stored
/// password (only a fixed placeholder when one is set), so a blank
/// submission is far more likely to mean "I didn't mean to change it"
/// than "clear my password" - it's treated as "keep the current value"
/// (a null result) rather than overwriting it with an empty string.
/// Checked via [String.trim] so an accidental space-bar press in the
/// obscured field can't silently replace a real password either; a
/// literal whitespace password is still settable when none existed yet.
String? resolvePasswordEdit(String submittedValue, bool hadExistingPassword) {
  if (submittedValue.trim().isEmpty && hadExistingPassword) {
    return null;
  }
  return submittedValue;
}

class PreferencesPage extends StatefulWidget {
  /// Displays this preferences page with information about the app.
  const PreferencesPage({super.key});

  @override
  State<StatefulWidget> createState() {
    return _PreferencesPageState();
  }
}

class _PreferencesPageState extends State<PreferencesPage> {
  bool _archivingLoading = true;
  bool _archivingAllEnabled = false;
  final _archiveDefaultsFormKey = GlobalKey<FormState>();
  final _defaultPollIntervalController = TextEditingController();
  final _defaultRetentionDaysController = TextEditingController();
  bool _appleAuthEnabled = false;
  bool _appleAuthStatusLoading = false;
  AppleAuthStatus? _appleAuthStatus;

  @override
  void initState() {
    super.initState();
    _loadArchivingStatus();
    _appleAuthEnabled = Settings.getValue<bool>(appleAuthEnabledKey, defaultValue: false) ?? false;
    if (_appleAuthEnabled) {
      _loadAppleAuthStatus();
    }
  }

  @override
  void dispose() {
    _defaultPollIntervalController.dispose();
    _defaultRetentionDaysController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: <Widget>[
          _sectionHeader(context, 'General'),
          getLocationTile(),
          getFetchOnStartupTile(),
          getNumberofDaysTile(),
          getTimeFormatTile(),
          getThemeModeTile(),
          _sectionHeader(context, 'Endpoint Connection'),
          getUrlTile(),
          getUserTile(),
          getPassTile(),
          _sectionHeader(context, 'Apple Account'),
          getAppleAuthTile(),
          if (_appleAuthEnabled) getAppleAuthAccountTile(),
          _sectionHeader(context, 'History Archiving'),
          getArchiveDefaultsSection(),
          getArchiveAllTile(),
          const Divider(height: 32),
          ListTile(
            title: getAbout(),
          ),
        ],
      ),
    );
  }

  /// A small, all-caps label separating groups of related settings, so a
  /// long flat list of switches/fields reads as a set of distinct
  /// sections instead of one undifferentiated block.
  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
      ),
    );
  }

  Widget getLocationTile() {
    return SwitchSettingsTile(
      settingKey: locationAccessWantedKey,
      title: "Show this device's location",
      activeColor: Theme.of(context).colorScheme.onPrimary,
      onChange: (showLocation) {
        var locationModel = Provider.of<LocationModel>(context, listen: false);
        if (showLocation) {
          locationModel.requestLocationUpdates();
        } else {
          locationModel.cancelLocationUpdates();
        }
      },
    );
  }

  Widget getNumberofDaysTile() {
    return const DropDownSettingsTile<int>(
      title: 'Number of days to fetch location',
      settingKey: numberOfDaysToFetch,
      values: <int, String>{
        0: "Latest location only",
        1: "1",
        2: "2",
        3: "3",
        4: "4",
        5: "5",
        6: "6",
        7: "7",
      },
      selected: 7,
    );
  }

  Widget getTimeFormatTile() {
    return const DropDownSettingsTile<String>(
      title: 'Time format',
      settingKey: timeFormatKey,
      values: <String, String>{
        timeFormatSystemValue: 'System default',
        timeFormatH12Value: '12-hour',
        timeFormatH24Value: '24-hour',
      },
      selected: timeFormatSystemValue,
    );
  }

  Widget getThemeModeTile() {
    return DropDownSettingsTile<String>(
      title: 'Theme',
      settingKey: themeModeKey,
      values: const <String, String>{
        themeModeSystemValue: 'System default',
        themeModeLightValue: 'Light',
        themeModeDarkValue: 'Dark',
      },
      selected: themeModeSystemValue,
      onChange: (value) {
        var themeModel = Provider.of<ThemeModel>(context, listen: false);
        themeModel.setMode(themeModeFromString(value));
      },
    );
  }

  Widget getUrlTile() {
    return TextInputSettingsTile(
      initialValue: 'http://localhost:6176',
      settingKey: endpointUrl,
      title: 'URL to Macless Haystack endpoint',
      validator: (String? url) {
        if (url != null &&
            url.startsWith(RegExp('http[s]?://', caseSensitive: false))) {
          return null;
        }
        return "Invalid URL";
      },
    );
  }

  Widget getUserTile() {
    return const TextInputSettingsTile(
      initialValue: '',
      settingKey: endpointUser,
      title: 'Username for endpoint',
    );
  }

  Widget getPassTile() {
    return ValueChangeObserver<String>(
      cacheKey: endpointPass,
      defaultValue: '',
      builder: (context, value, onChanged) {
        return ListTile(
          title: Text(passwordFieldTitle(value)),
          trailing: const Icon(Icons.edit),
          onTap: () async {
            var submitted = await showDialog<(String, bool)>(
              context: context,
              builder: (context) =>
                  _PasswordEditDialog(hasExistingPassword: value.isNotEmpty),
            );
            if (submitted == null) return;
            var (text, clear) = submitted;
            if (clear) {
              var previousValue = value;
              onChanged('');
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Password cleared'),
                    action: SnackBarAction(
                      label: 'Undo',
                      onPressed: () => onChanged(previousValue),
                    ),
                  ),
                );
              }
              return;
            }
            var resolved = resolvePasswordEdit(text, value.isNotEmpty);
            if (resolved != null && resolved != value) {
              onChanged(resolved);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password updated')),
                );
              }
            }
          },
        );
      },
    );
  }

  Widget getAbout() {
    return TextButton(
        style: ButtonStyle(
            padding:
                WidgetStateProperty.all<EdgeInsets>(const EdgeInsets.all(10)),
            foregroundColor: WidgetStateProperty.resolveWith<Color?>(
              (Set<WidgetState> states) {
                return Colors.white;
              },
            ),
            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
              (Set<WidgetState> states) {
                return Colors.indigo;
              },
            )),
        child: const Text('About'),
        onPressed: () async {
          var packageInfo = await PackageInfo.fromPlatform();
          if (!mounted) return;
          showAboutDialog(
            context: context,
            applicationName: packageInfo.appName,
            applicationVersion: packageInfo.buildNumber.isEmpty
                ? packageInfo.version
                : '${packageInfo.version}+${packageInfo.buildNumber}',
            applicationLegalese:
                'Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).',
          );
        });
  }

  Widget getFetchOnStartupTile() {
    return SwitchSettingsTile(
      settingKey: fetchLocationOnStartupKey,
      defaultValue: true,
      title: 'Fetch locations on startup',
      activeColor: Theme.of(context).colorScheme.onPrimary,
    );
  }

  Set<String> _allKnownKeys(Iterable<Accessory> accessories) {
    var keys = <String>{};
    for (var accessory in accessories) {
      keys.add(accessory.hashedPublicKey);
      keys.addAll(accessory.additionalKeys);
    }
    return keys;
  }

  Future<void> _loadArchivingStatus() async {
    try {
      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
      var accessories = Provider.of<AccessoryRegistry>(context, listen: false).accessories;
      var allKeys = _allKnownKeys(accessories);

      var devices = await HistoryArchiveService.getArchivedDevices(url, user, pass);
      var enabledKeys = devices.where((d) => d.enabled).map((d) => d.hashedPublicKey).toSet();
      var allEnabled = allKeys.isNotEmpty && allKeys.every(enabledKeys.contains);

      if (mounted) {
        setState(() {
          _archivingAllEnabled = allEnabled;
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

  Future<void> _loadAppleAuthStatus() async {
    setState(() => _appleAuthStatusLoading = true);
    try {
      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
      var status = await AppleAuthService.getStatus(url, user, pass);
      if (mounted) {
        setState(() {
          _appleAuthStatus = status;
          _appleAuthStatusLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _appleAuthStatus = null;
          _appleAuthStatusLoading = false;
        });
      }
    }
  }

  String _appleAuthStatusLabel() {
    if (_appleAuthStatusLoading) return 'Checking status…';
    var status = _appleAuthStatus;
    if (status == null) return 'Could not reach the endpoint';
    if (status.pending) return 'Login in progress';
    return status.loggedIn ? 'Logged in' : 'Needs re-login';
  }

  Widget getAppleAuthTile() {
    return SwitchSettingsTile(
      settingKey: appleAuthEnabledKey,
      defaultValue: false,
      title: 'Enable in-app Apple ID login',
      activeColor: Theme.of(context).colorScheme.onPrimary,
      onChange: (enabled) {
        setState(() {
          _appleAuthEnabled = enabled;
          if (!enabled) {
            // The endpoint can be repointed while the switch is off, so a kept
            // status would describe the wrong server on re-enable.
            _appleAuthStatus = null;
          }
        });
        if (enabled) {
          _loadAppleAuthStatus();
        }
      },
    );
  }

  Widget getAppleAuthAccountTile() {
    return ListTile(
      title: const Text('Apple Account'),
      subtitle: Text(_appleAuthStatusLabel()),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
        var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
        var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => AppleAuthPage(
              endpointUrl: url,
              endpointUser: user,
              endpointPass: pass,
              initialLoggedIn: _appleAuthStatus?.loggedIn ?? false,
            ),
          ),
        );
        // Always refresh, regardless of how the page was left (login
        // success, logout, or just navigating back) - there's no reliable
        // pop value to branch on, since the system back gesture bypasses
        // any in-page pop-value plumbing. One extra GET on a plain
        // cancel is a cheap price for never showing stale status.
        _loadAppleAuthStatus();
      },
    );
  }

  /// Builds the [HistoryDeviceEntry] list for [accessory]'s main key and any
  /// additional keys, shared by every place that pushes an archiving state
  /// (or setting) to the server for that accessory.
  Future<List<HistoryDeviceEntry>> _deviceEntriesFor(Accessory accessory, bool enabled,
      {int? pollIntervalHours, int? retentionDays}) async {
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

  Future<void> _setArchivingAll(bool enabled) async {
    var accessories = Provider.of<AccessoryRegistry>(context, listen: false).accessories;
    if (accessories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No accessories to archive')),
      );
      return;
    }

    var previous = _archivingAllEnabled;
    setState(() {
      _archivingAllEnabled = enabled;
    });
    try {
      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;

      List<HistoryDeviceEntry> devices = [];
      for (var accessory in accessories) {
        devices.addAll(await _deviceEntriesFor(accessory, enabled));
      }

      if (devices.isNotEmpty) {
        await HistoryArchiveService.setDevicesArchiving(url, user, pass, devices);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _archivingAllEnabled = previous;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update endpoint archiving: $e')),
        );
      }
    }
  }

  /// Applies the entered poll interval/retention to every device that is
  /// currently archived on the server. This only updates those settings -
  /// it never enables archiving for a device that's currently off, and
  /// never touches the "Archive all accessories on endpoint" switch.
  Future<void> _applyDefaultsToAll() async {
    if (_archiveDefaultsFormKey.currentState?.validate() != true) {
      return;
    }
    var accessories = Provider.of<AccessoryRegistry>(context, listen: false).accessories;
    if (accessories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No accessories to update')),
      );
      return;
    }

    var pollIntervalText = _defaultPollIntervalController.text.trim();
    var retentionText = _defaultRetentionDaysController.text.trim();
    if (pollIntervalText.isEmpty && retentionText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a poll interval or retention value first')),
      );
      return;
    }

    try {
      var pollIntervalHours =
          pollIntervalText.isEmpty ? null : int.parse(pollIntervalText);
      var retentionDays =
          retentionText.isEmpty ? null : int.parse(retentionText);

      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;

      var currentDevices = await HistoryArchiveService.getArchivedDevices(url, user, pass);
      var enabledKeys = currentDevices.where((d) => d.enabled).map((d) => d.hashedPublicKey).toSet();

      List<HistoryDeviceEntry> devices = [];
      for (var accessory in accessories) {
        var entries = await _deviceEntriesFor(accessory, true,
            pollIntervalHours: pollIntervalHours, retentionDays: retentionDays);
        devices.addAll(entries.where((e) => enabledKeys.contains(e.hashedPublicKey)));
      }

      if (devices.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No accessories are currently archived on the endpoint')),
          );
        }
        return;
      }

      await HistoryArchiveService.setDevicesArchiving(url, user, pass, devices);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Archive settings applied to all archived accessories')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update archive settings: $e')),
        );
      }
    }
  }

  Widget getArchiveDefaultsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Form(
        key: _archiveDefaultsFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Poll interval and retention for accessories already archived on '
                "the endpoint. Leave a field blank to keep each accessory's "
                'existing value. Tap Apply to push these to every currently '
                'archived accessory - accessories not currently archived are not '
                'affected or turned on.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            TextFormField(
              controller: _defaultPollIntervalController,
              decoration:
                  const InputDecoration(labelText: 'Default poll interval (hours)'),
              keyboardType: TextInputType.number,
              validator: validateOptionalPollIntervalHours,
            ),
            TextFormField(
              controller: _defaultRetentionDaysController,
              decoration:
                  const InputDecoration(labelText: 'Default retention (days)'),
              keyboardType: TextInputType.number,
              validator: validateOptionalRetentionDays,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _applyDefaultsToAll,
                child: const Text('Apply to archived accessories'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget getArchiveAllTile() {
    return SwitchListTile(
      value: _archivingAllEnabled,
      title: const Text('Archive all accessories on endpoint'),
      subtitle: _archivingLoading ? const Text('Loading status…') : null,
      onChanged: _archivingLoading ? null : _setArchivingAll,
    );
  }
}

/// Edits the endpoint password without ever displaying or pre-filling the
/// real stored value - the field always starts empty, with a fixed-length
/// placeholder hint (not the real password's length) shown only when one is
/// already set.
class _PasswordEditDialog extends StatefulWidget {
  final bool hasExistingPassword;

  const _PasswordEditDialog({required this.hasExistingPassword});

  @override
  State<_PasswordEditDialog> createState() => _PasswordEditDialogState();
}

class _PasswordEditDialogState extends State<_PasswordEditDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Password for endpoint'),
      content: TextField(
        controller: _controller,
        obscureText: true,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        onSubmitted: (text) => Navigator.pop(context, (text, false)),
        decoration: InputDecoration(
          hintText: widget.hasExistingPassword ? '••••' : null,
          helperText: widget.hasExistingPassword
              ? 'Leave blank to keep the current password'
              : null,
        ),
      ),
      actions: [
        if (widget.hasExistingPassword)
          TextButton(
            onPressed: () => Navigator.pop(context, ('', true)),
            child: const Text('Clear'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, (_controller.text, false)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
