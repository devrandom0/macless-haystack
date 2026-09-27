import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/history/accessory_history.dart';
import 'package:macless_haystack/refresh_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

Accessory _accessory({bool isActive = true}) {
  return Accessory(
    id: 'a',
    name: 'Keys',
    hashedPublicKey: 'hash',
    datePublished: DateTime.now(),
    isActive: isActive,
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

Future<void> _pump(
  WidgetTester tester, {
  required Accessory accessory,
  required RefreshCoordinator refreshCoordinator,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AccessoryHistory(
      accessory: accessory,
      refreshCoordinator: refreshCoordinator,
    ),
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Settings.init();
  });

  testWidgets('shows a Refresh action in the app bar', (tester) async {
    await _pump(
      tester,
      accessory: _accessory(),
      refreshCoordinator: RefreshCoordinator(
        (accessory, {force = false, showFeedback = true}) async {},
      ),
    );

    expect(_refreshButton, findsOneWidget);
    expect(
      find.descendant(of: _refreshButton, matching: find.byIcon(Icons.refresh)),
      findsOneWidget,
    );
  });

  testWidgets('tapping Refresh calls back with this accessory', (tester) async {
    var calledWith = <Accessory?>[];
    var accessory = _accessory();

    await _pump(
      tester,
      accessory: accessory,
      refreshCoordinator: RefreshCoordinator(
        (accessory, {force = false, showFeedback = true}) async {
          calledWith.add(accessory);
        },
      ),
    );

    await tester.tap(_refreshButton);
    await tester.pump();

    expect(calledWith, [accessory]);
  });

  testWidgets(
      'shows a progress indicator and disables the button while refreshing',
      (tester) async {
    var completer = Completer<void>();

    await _pump(
      tester,
      accessory: _accessory(),
      refreshCoordinator: RefreshCoordinator(
        (accessory, {force = false, showFeedback = true}) => completer.future,
      ),
    );

    await tester.tap(_refreshButton);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    var button = tester.widget<IconButton>(_refreshButton);
    expect(button.onPressed, isNull);

    completer.complete();
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    button = tester.widget<IconButton>(_refreshButton);
    expect(button.onPressed, isNotNull);
  });

  testWidgets('a second tap while refreshing is a no-op', (tester) async {
    var callCount = 0;
    var completer = Completer<void>();

    await _pump(
      tester,
      accessory: _accessory(),
      refreshCoordinator: RefreshCoordinator(
        (accessory, {force = false, showFeedback = true}) {
          callCount++;
          return completer.future;
        },
      ),
    );

    await tester.tap(_refreshButton);
    await tester.pump();
    // The button is disabled now (see the test above), so this tap must not
    // reach the button's onPressed at all.
    await tester.tap(_refreshButton, warnIfMissed: false);
    await tester.pump();

    expect(callCount, 1);

    completer.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('an inactive accessory has no working Refresh action',
      (tester) async {
    var called = false;

    await _pump(
      tester,
      accessory: _accessory(isActive: false),
      refreshCoordinator: RefreshCoordinator(
        (accessory, {force = false, showFeedback = true}) async {
          called = true;
        },
      ),
    );

    var button = tester.widget<IconButton>(_refreshButton);
    expect(button.onPressed, isNull);
    expect(called, isFalse);
  });

  testWidgets('a throwing refresh still resets the spinner', (tester) async {
    var completer = Completer<void>();

    await _pump(
      tester,
      accessory: _accessory(),
      refreshCoordinator: RefreshCoordinator(
        (accessory, {force = false, showFeedback = true}) => completer.future,
      ),
    );

    await tester.tap(_refreshButton);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.completeError(Exception('boom'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    var button = tester.widget<IconButton>(_refreshButton);
    expect(button.onPressed, isNotNull);
  });

  testWidgets('popping the history page mid-refresh does not throw',
      (tester) async {
    var completer = Completer<void>();
    var refreshCoordinator = RefreshCoordinator(
      (accessory, {force = false, showFeedback = true}) => completer.future,
    );
    var accessory = _accessory();

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => AccessoryHistory(
                    accessory: accessory,
                    refreshCoordinator: refreshCoordinator,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.widgetWithText(ElevatedButton, 'open'));
    await tester.pumpAndSettle();

    await tester.tap(_refreshButton);
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AccessoryHistory), findsNothing);

    completer.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('shows newly fetched history once a refresh resolves',
      (tester) async {
    var accessory = _accessory();
    var now = DateTime.now();

    await _pump(
      tester,
      accessory: accessory,
      refreshCoordinator: RefreshCoordinator(
        (accessory, {force = false, showFeedback = true}) async {
          // A real async gap, not a synchronous mutation - mirrors
          // AccessoryRegistry.loadLocationReports actually awaiting its
          // history work before returning, and mutating the same
          // accessory instance in place rather than replacing it.
          await Future.delayed(const Duration(milliseconds: 10));
          accessory!.locationHistory.add(
            Pair(const LatLng(11, 11), now, now),
          );
        },
      ),
    );

    expect(find.text('0 history reports'), findsOneWidget);

    await tester.tap(_refreshButton);
    await tester.pump();
    // Still in flight - the delayed mutation hasn't landed yet.
    expect(find.text('0 history reports'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('1 history report'), findsOneWidget);
  });
}
