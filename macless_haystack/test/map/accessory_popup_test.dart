import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/map/accessory_popup.dart';
import 'package:shared_preferences/shared_preferences.dart';

Accessory _accessory() {
  return Accessory(
    id: 'a',
    name: 'Keys',
    hashedPublicKey: 'hash',
    datePublished: DateTime.now(),
    lastLocation: const LatLng(10, 10),
    hashesWithTS: {},
    locationHistory: [],
    lastBatteryStatus: null,
    additionalKeys: [],
  );
}

final _refreshButton = find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == 'Refresh this accessory',
);

/// [Marker] (which [AccessoryPopup] extends) is not itself a widget - only
/// its [Marker.child] is - so the popup's content can be pumped directly,
/// without the FlutterMap/Provider scaffolding the real map screen needs.
Future<void> _pump(
  WidgetTester tester, {
  required VoidCallback onRefresh,
  bool refreshing = false,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AccessoryPopup(
        accessory: _accessory(),
        onNavigate: () {},
        onHistory: () {},
        onShare: () {},
        onRefresh: onRefresh,
        refreshing: refreshing,
      ).child,
    ),
  ));
  // _PopupContent fades/scales itself in over 180ms (TweenAnimationBuilder) -
  // without waiting that out, a tap lands on the not-yet-scaled-up
  // (effectively zero-size) content and misses every button. A fixed
  // duration is used instead of pumpAndSettle because the refreshing state
  // renders an indeterminate CircularProgressIndicator, which never settles.
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.init();
  });

  testWidgets('shows a Refresh action alongside Navigate/History/Share',
      (tester) async {
    await _pump(tester, onRefresh: () {});

    expect(_refreshButton, findsOneWidget);
    expect(find.byTooltip('Navigate'), findsOneWidget);
    expect(find.byTooltip('History'), findsOneWidget);
    expect(find.byTooltip('Share'), findsOneWidget);
  });

  testWidgets('tapping Refresh invokes the callback', (tester) async {
    var tapped = 0;
    await _pump(tester, onRefresh: () => tapped++);

    await tester.tap(_refreshButton);
    await tester.pump();

    expect(tapped, 1);
  });

  testWidgets('refreshing shows a progress indicator and disables the button',
      (tester) async {
    await _pump(tester, onRefresh: () {}, refreshing: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    var button = tester.widget<IconButton>(_refreshButton);
    expect(button.onPressed, isNull);

    // The other actions stay usable while only the refresh is in flight.
    var navigateButton = tester.widget<IconButton>(find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Navigate',
    ));
    expect(navigateButton.onPressed, isNotNull);
  });
}
