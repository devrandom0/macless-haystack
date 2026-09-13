
import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:logger/logger.dart';
import 'package:macless_haystack/item_management/refresh_action.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/dashboard/accessory_map_list_vert.dart';
import 'package:macless_haystack/item_management/item_management.dart';
import 'package:macless_haystack/item_management/new_item_action.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/preferences/preferences_page.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

import '../accessory/accessory_model.dart';

class Dashboard extends StatefulWidget {
  /// Displays the layout for the mobile view of the app.
  ///
  /// The layout is optimized for a vertically aligned small screens.
  /// The functionality is structured in a bottom tab bar for easy access
  /// on mobile devices.
  const Dashboard({super.key});

  @override
  State<StatefulWidget> createState() {
    return _DashboardState();
  }
}

class _DashboardState extends State<Dashboard> {
  /// A list of the tabs displayed in the bottom tab bar.
  ///
  /// Only the per-tab chrome (icon/label/action button) lives here - the
  /// tab bodies themselves are built once into [_tabBodies] and kept alive
  /// via IndexedStack, see its field doc.
  late final List<Map<String, dynamic>> _tabs = [
    {
      'icon': Icons.place,
      'label': 'Map',
      'actionButton': (ctx) => RefreshAction(
            callback: () async {
              await loadLocationUpdates(null);
            },
          ),
    },
    {
      'icon': Icons.inventory_2,
      'label': 'Accessories',
      'actionButton': (ctx) => const NewKeyAction(),
    },
  ];

  /// The tab bodies, built once and kept mounted via IndexedStack so a
  /// tab's own State (e.g. AccessoryList's collapsed-groups) survives
  /// switching away and back, instead of being torn down and recreated.
  late final List<Widget> _tabBodies = [
    AccessoryMapListVertical(
      loadLocationUpdates: loadLocationUpdates,
      saveOrderUpdatesCallback: saveAccessories,
    ),
    const KeyManagement(),
  ];

  @override
  void initState() {
    super.initState();

    // Initialize models and preferences
    var userPreferences = Provider.of<UserPreferences>(context, listen: false);
    var locationModel = Provider.of<LocationModel>(context, listen: false);
    var locationPreferenceKnown =
        userPreferences.locationPreferenceKnown ?? false;
    var locationAccessWanted = userPreferences.locationAccessWanted ?? false;
    if (!locationPreferenceKnown || locationAccessWanted) {
      locationModel.requestLocationUpdates();
    }
    // Load new location reports on app start
    if (Settings.getValue<bool>(fetchLocationOnStartupKey,
        defaultValue: true)!) {
      loadLocationUpdates(null);
    }
  }

  var logger = Logger(
    printer: PrettyPrinter(),
  );

  /// Fetch location updates for all accessories.
  Future<void> loadLocationUpdates(Accessory? accessory) async {
    var accessoryRegistry =
        Provider.of<AccessoryRegistry>(context, listen: false);
    var inactive = 0;
    Iterable<Accessory> accessories;
    if (accessory == null) {
      accessories = accessoryRegistry.accessories;
      inactive = accessories.where((a) => !a.isActive).length;
    } else {
      accessories = [accessory];
    }
    try {
      var count = await accessoryRegistry
          .loadLocationReports(accessories.where((a) => a.isActive));
      if (mounted && accessories.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            content: Text(
              'Fetched $count location(s).${inactive > 0 ? ' $inactive inactive ${inactive == 1 ? 'accessory' : 'accessories'} skipped' : ''}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        );
      }
    } catch (e, stacktrace) {
      // The exception detail is logged, not shown - a raw exception string
      // ("SocketException: ...", "FormatException: ...") isn't something a
      // user can act on, and this same message otherwise fires for a wrong
      // URL, a wrong password, and a dead network alike.
      logger.e('Error on fetching', error: e, stackTrace: stacktrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.error,
            content: Text(
              'Could not reach the endpoint. Check the URL, username, and '
              'password in Settings, then try again.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onError,
              ),
            ),
            action: SnackBarAction(
              label: 'Retry',
              textColor: Theme.of(context).colorScheme.onError,
              onPressed: () => loadLocationUpdates(accessory),
            ),
          ),
        );
      }
    }
  }

  /// The selected tab index.
  int _selectedIndex = 0;

  /// Updates the currently displayed tab to [index].
  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text(_tabs[_selectedIndex]['label'] as String),
          actions: <Widget>[
            IconButton(
              tooltip: 'Settings',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const PreferencesPage()),
                );
              },
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
        body: IndexedStack(
          index: _selectedIndex,
          children: _tabBodies,
        ),
        bottomNavigationBar: NavigationBar(
          destinations: _tabs
              .map((tab) => NavigationDestination(
                    icon: Icon(tab['icon']),
                    label: tab['label'],
                  ))
              .toList(),
          selectedIndex: _selectedIndex,
          onDestinationSelected: _onItemTapped,
        ),
        floatingActionButton:
            _tabs[_selectedIndex]['actionButton']?.call(context),
        // endDocked is meant to notch into a BottomAppBar; against a plain
        // bottom nav bar it instead parks the FAB half-sunk on top of the
        // second tab's own hit area.
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat);
  }

  Future<void> saveAccessories(List<Accessory> accessories) async {
    var accessoryRegistry =
        Provider.of<AccessoryRegistry>(context, listen: false);
    accessoryRegistry.saveOrderUpdates(accessories);
  }
}
