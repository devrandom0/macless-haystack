import 'package:flutter/material.dart';
import 'package:macless_haystack/accessory/secure_storage_upgrade.dart';
import 'package:macless_haystack/dashboard/dashboard.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/map/map_tile_provider_model.dart';
import 'package:macless_haystack/map/map_tile_source.dart';
import 'package:macless_haystack/preferences/theme_model.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
import 'package:macless_haystack/splashscreen.dart';
import 'package:macless_haystack/theme/app_theme.dart';
import 'package:macless_haystack/util/theme_mode.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:intl/date_symbol_data_local.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.init();
  await initializeDateFormatting();
  var initialThemeMode = themeModeFromString(
      Settings.getValue<String>(themeModeKey, defaultValue: themeModeSystemValue));
  var initialMapTileProvider = Settings.getValue<String>(mapTileProviderKey,
      defaultValue: mapTileProviderOsmValue)!;
  runApp(MyApp(
    initialThemeMode: initialThemeMode,
    initialMapTileProvider: initialMapTileProvider,
  ));
}

class MyApp extends StatelessWidget {
  final ThemeMode initialThemeMode;
  final String initialMapTileProvider;

  const MyApp({
    super.key,
    required this.initialThemeMode,
    required this.initialMapTileProvider,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (ctx) => AccessoryRegistry()),
        ChangeNotifierProvider(create: (ctx) => UserPreferences()),
        ChangeNotifierProvider(create: (ctx) => LocationModel()),
        ChangeNotifierProvider(create: (ctx) => ThemeModel(initialThemeMode)),
        ChangeNotifierProvider(
            create: (ctx) => MapTileProviderModel(initialMapTileProvider)),
      ],
      child: Consumer<ThemeModel>(
        builder: (context, themeModel, child) {
          return MaterialApp(
            title: 'Macless Haystack',
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: themeModel.mode,
            home: const AppLayout(),
          );
        },
      ),
    );
  }
}

class AppLayout extends StatefulWidget {
  const AppLayout({super.key});

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  bool _storageWarningShown = false;

  @override
  initState() {
    super.initState();

    var accessoryRegistry =
        Provider.of<AccessoryRegistry>(context, listen: false);
    accessoryRegistry.loadAccessories();
    accessoryRegistry.checkStorageUpgradeStatus();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    // Precache logo for faster load times (e.g. on the splash screen)
    precacheImage(const AssetImage('assets/OpenHaystackIcon.png'), context);
    super.didChangeDependencies();
  }

  void _maybeShowStorageWarning(BuildContext context, String warning) {
    if (_storageWarningShown) {
      return;
    }
    _storageWarningShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Secure storage warning'),
          content: Text(warning),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    bool isInitialized = context.watch<UserPreferences>().initialized;
    bool isLoading = context.watch<AccessoryRegistry>().loading;
    var storageUpgradeStatus =
        context.watch<AccessoryRegistry>().storageUpgradeStatus;
    if (storageUpgradeStatus != null) {
      var warning = secureStorageUpgradeWarning(storageUpgradeStatus);
      if (warning != null) {
        _maybeShowStorageWarning(context, warning);
      }
    }
    if (!isInitialized || isLoading) {
      return const Splashscreen();
    }

    return const Dashboard();
  }
}
