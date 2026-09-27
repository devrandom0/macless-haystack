import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/map/accessory_popup.dart';
import 'package:macless_haystack/refresh_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

Accessory _accessory({String id = 'a'}) {
  return Accessory(
    id: id,
    name: 'Keys',
    hashedPublicKey: 'hash-$id',
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

  testWidgets(
      'switching the selected marker mid-refresh leaves the other accessory refreshable',
      (tester) async {
    var completerA = Completer<void>();
    var callCounts = <String, int>{};
    var coordinator = RefreshCoordinator(
      (accessory, {force = false, showFeedback = true}) async {
        callCounts[accessory!.id] = (callCounts[accessory.id] ?? 0) + 1;
        if (accessory.id == 'a') {
          await completerA.future;
        }
      },
    );
    var accessoryA = _accessory(id: 'a');
    var accessoryB = _accessory(id: 'b');

    // A's refresh is started and still in flight when B becomes the
    // selected marker below - this mirrors the map switching selection
    // while a previous accessory's refresh is still running.
    coordinator.refresh(accessoryA);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<Set<String>>(
          valueListenable: coordinator,
          builder: (context, refreshingIds, child) {
            return AccessoryPopup(
              accessory: accessoryB,
              onNavigate: () {},
              onHistory: () {},
              onShare: () {},
              onRefresh: () => coordinator.refresh(accessoryB),
              refreshing: refreshingIds.contains(accessoryB.id),
            ).child;
          },
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    var button = tester.widget<IconButton>(_refreshButton);
    expect(button.onPressed, isNotNull);

    await tester.tap(_refreshButton);
    await tester.pump();

    expect(callCounts['b'], 1);
    expect(coordinator.isRefreshing('a'), isTrue);

    completerA.complete();
    await tester.pump();
  });
}
