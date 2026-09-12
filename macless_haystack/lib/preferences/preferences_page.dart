import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
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

  @override
  void initState() {
    super.initState();
    _loadArchivingStatus();
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
      body: Center(
        child: Column(
          children: <Widget>[
            getLocationTile(),
            getFetchOnStartupTile(),
            getUrlTile(),
            getUserTile(),
            getPassTile(),
            getNumberofDaysTile(),
            getTimeFormatTile(),
            getThemeModeTile(),
            getArchiveDefaultsSection(),
            getArchiveAllTile(),
            ListTile(
              title: getAbout(),
            ),
          ],
        ),
      ),
    );
  }

  Widget getLocationTile() {
    return SwitchSettingsTile(
      settingKey: locationAccessWantedKey,
      title: 'Show this devices location',
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
        0: "latest location only",
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
      title: 'Url to macless haystack endpoint',
      validator: (String? url) {
        if (url != null &&
            url.startsWith(RegExp('http[s]?://', caseSensitive: false))) {
          return null;
        }
        return "Invalid Url";
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
        return TextInputSettingsTile(
          obscureText: true,
          initialValue: '',
          settingKey: endpointPass,
          title: passwordFieldTitle(value),
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
        const SnackBar(content: Text('No devices to archive')),
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
          SnackBar(content: Text('Could not update server-side archiving: $e')),
        );
      }
    }
  }

  /// Applies the entered poll interval/retention to every device that is
  /// currently archived on the server. This only updates those settings -
  /// it never enables archiving for a device that's currently off, and
  /// never touches the "Archive all devices on server" switch.
  Future<void> _applyDefaultsToAll() async {
    if (_archiveDefaultsFormKey.currentState?.validate() != true) {
      return;
    }
    var accessories = Provider.of<AccessoryRegistry>(context, listen: false).accessories;
    if (accessories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No devices to update')),
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
            const SnackBar(content: Text('No devices are currently archived on the server')),
          );
        }
        return;
      }

      await HistoryArchiveService.setDevicesArchiving(url, user, pass, devices);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Archive settings applied to all archived devices')),
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
                'Poll interval and retention for devices already archived on '
                "the server. Leave a field blank to keep each device's "
                'existing value. Tap Apply to push these to every currently '
                'archived device - devices not currently archived are not '
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
                child: const Text('Apply to archived devices'),
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
      title: const Text('Archive all devices on server'),
      subtitle: _archivingLoading ? const Text('Loading status…') : null,
      onChanged: _archivingLoading ? null : _setArchivingAll,
    );
  }
}
