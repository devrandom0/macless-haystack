import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/history/history_archive_service.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
import 'package:macless_haystack/util/time_format.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';

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

  @override
  void initState() {
    super.initState();
    _loadArchivingStatus();
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
            getArchiveAllTile(),
            ListTile(
              title: getAbout(),
            ),
          ],
        ),
      ),
    );
  }

  getLocationTile() {
    return SwitchSettingsTile(
      settingKey: locationAccessWantedKey,
      title: 'Show this devices location',
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

  getNumberofDaysTile() {
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

  getTimeFormatTile() {
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

  getUrlTile() {
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

  getUserTile() {
    return const TextInputSettingsTile(
      initialValue: '',
      settingKey: endpointUser,
      title: 'Username for endpoint',
    );
  }

  getPassTile() {
    return const TextInputSettingsTile(
      obscureText: true,
      initialValue: '',
      settingKey: endpointPass,
      title: 'Password for endpoint',
    );
  }

  getAbout() {
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
        onPressed: () => showAboutDialog(
              context: context,
            ));
  }

  getFetchOnStartupTile() {
    return SwitchSettingsTile(
      settingKey: fetchLocationOnStartupKey,
      defaultValue: true,
      title: 'Fetch locations on startup',
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
        var additionalPrivateKeys = await accessory.getAdditionalPrivateKeys();
        devices.add(HistoryDeviceEntry(
          hashedPublicKey: accessory.hashedPublicKey,
          privateKey: await accessory.getPrivateKey(),
          name: accessory.name,
          accessoryId: accessory.id,
          enabled: enabled,
        ));
        for (var i = 0; i < accessory.additionalKeys.length; i++) {
          devices.add(HistoryDeviceEntry(
            hashedPublicKey: accessory.additionalKeys[i],
            privateKey: additionalPrivateKeys[i],
            name: '${accessory.name} (extra key)',
            accessoryId: accessory.id,
            enabled: enabled,
          ));
        }
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

  getArchiveAllTile() {
    return SwitchListTile(
      value: _archivingAllEnabled,
      title: const Text('Archive all devices on server'),
      subtitle: _archivingLoading ? const Text('Loading status…') : null,
      onChanged: _archivingLoading ? null : _setArchivingAll,
    );
  }
}
