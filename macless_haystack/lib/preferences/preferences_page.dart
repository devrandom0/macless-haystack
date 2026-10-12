import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
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
            getAppleIdTile(),
            getNumberofDaysTile(),
            ListTile(
              title: getAbout(),
            ),
          ],
        ),
      ),
    );
  }

  getAppleIdTile() {
    return ListTile(
      leading: const Icon(Icons.apple),
      title: const Text('Apple Find My Login'),
      subtitle: const Text('Log into Apple ID via endpoint to fetch account devices'),
      trailing: ElevatedButton(
        child: const Text('Login'),
        onPressed: () => _showAppleLoginDialog(),
      ),
    );
  }

  void _showAppleLoginDialog() {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apple ID Login'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(labelText: 'Apple ID Email'),
            ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ElevatedButton(
            child: const Text('Sign In'),
            onPressed: () async {
              final user = usernameController.text.trim();
              final pass = passwordController.text;
              Navigator.of(ctx).pop();
              if (user.isEmpty || pass.isEmpty) return;

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logging into Apple ID...')),
              );

              String? url = Settings.getValue<String>(endpointUrl);
              if (url == null || url.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please configure the endpoint URL first')),
                );
                return;
              }

              try {
                final loginUri = Uri.parse(url.endsWith('/') ? '${url}api/auth/login' : '$url/api/auth/login');
                final response = await http.post(
                  loginUri,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'username': user, 'password': pass}),
                );
                final res = jsonDecode(response.body);
                if (res['state'] == 'REQUIRE_2FA') {
                  if (mounted) _show2FADialog(url);
                } else if (res['logged_in'] == true) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Apple ID Login Successful! Refreshing devices...')),
                    );
                    Provider.of<AccessoryRegistry>(context, listen: false).loadAccessories();
                  }
                } else {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Login failed: ${res['error'] ?? res['state']}')),
                    );
                  }
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error connecting to endpoint: $e')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  void _show2FADialog(String url) {
    final codeController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter 2FA Code'),
        content: TextField(
          controller: codeController,
          decoration: const InputDecoration(labelText: 'Verification Code'),
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ElevatedButton(
            child: const Text('Submit'),
            onPressed: () async {
              final code = codeController.text.trim();
              Navigator.of(ctx).pop();
              if (code.isEmpty) return;

              try {
                final auth2faUri = Uri.parse(url.endsWith('/') ? '${url}api/auth/2fa' : '$url/api/auth/2fa');
                final response = await http.post(
                  auth2faUri,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'code': code, 'method': 'trusted_device'}),
                );
                final res = jsonDecode(response.body);
                if (res['success'] == true) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('2FA Verified! Refreshing devices...')),
                    );
                    Provider.of<AccessoryRegistry>(context, listen: false).loadAccessories();
                  }
                } else {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('2FA verification failed: ${res['error'] ?? res['state']}')),
                    );
                  }
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error submitting 2FA: $e')),
                  );
                }
              }
            },
          ),
        ],
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
}
