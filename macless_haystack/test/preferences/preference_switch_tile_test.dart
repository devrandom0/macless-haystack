import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macless_haystack/preferences/preference_switch_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.init();
  });

  Future<void> pumpTile(WidgetTester tester, String key,
      {bool defaultValue = true, ValueChanged<bool>? onChange}) {
    return tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(
        body: PreferenceSwitchTile(
          settingKey: key,
          defaultValue: defaultValue,
          title: 'A setting',
          subtitle: 'Explains it',
          onChange: onChange,
        ),
      ),
    ));
  }

  testWidgets('renders a stock Material switch with no forced thumb color',
      (tester) async {
    await pumpTile(tester, 'thumb-test');

    var tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.thumbColor, isNull);
    expect(tile.activeThumbColor, isNull);
    expect(tile.value, isTrue);
  });

  testWidgets('shows title and subtitle', (tester) async {
    await pumpTile(tester, 'text-test');

    expect(find.text('A setting'), findsOneWidget);
    expect(find.text('Explains it'), findsOneWidget);
  });

  testWidgets('tapping persists the new value and calls onChange',
      (tester) async {
    bool? changedTo;
    await pumpTile(tester, 'persist-test', onChange: (v) => changedTo = v);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(changedTo, isFalse);
    expect(Settings.getValue<bool>('persist-test'), isFalse);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
  });

  testWidgets('reflects a value changed elsewhere via Settings',
      (tester) async {
    await pumpTile(tester, 'observe-test', defaultValue: false);

    await Settings.setValue<bool>('observe-test', true, notify: true);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
  });
}
