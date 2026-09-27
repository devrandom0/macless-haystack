import 'dart:async';

import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/refresh_coordinator.dart';
import 'package:test/test.dart';

Accessory _accessory(String id) {
  return Accessory(
    id: id,
    name: id,
    hashedPublicKey: 'hash-$id',
    datePublished: DateTime.now(),
    lastLocation: const LatLng(10, 10),
    hashesWithTS: {},
    locationHistory: [],
    lastBatteryStatus: null,
    additionalKeys: [],
  );
}

void main() {
  test('isRefreshing is false before and after a refresh completes', () async {
    var coordinator = RefreshCoordinator((accessory, {force = false, showFeedback = true}) async {});
    var accessory = _accessory('a');

    expect(coordinator.isRefreshing(accessory.id), isFalse);
    await coordinator.refresh(accessory);
    expect(coordinator.isRefreshing(accessory.id), isFalse);
  });

  test('isRefreshing is true while the refresh is in flight', () async {
    var completer = Completer<void>();
    var coordinator = RefreshCoordinator(
      (accessory, {force = false, showFeedback = true}) => completer.future,
    );
    var accessory = _accessory('a');

    var future = coordinator.refresh(accessory);
    expect(coordinator.isRefreshing(accessory.id), isTrue);

    completer.complete();
    await future;
    expect(coordinator.isRefreshing(accessory.id), isFalse);
  });

  test('a second refresh for the same accessory while one is in flight is a no-op', () async {
    var completer = Completer<void>();
    var callCount = 0;
    var coordinator = RefreshCoordinator((accessory, {force = false, showFeedback = true}) async {
      callCount++;
      await completer.future;
    });
    var accessory = _accessory('a');

    var first = coordinator.refresh(accessory);
    await coordinator.refresh(accessory);

    expect(callCount, 1);
    expect(coordinator.isRefreshing(accessory.id), isTrue);

    completer.complete();
    await first;
    expect(coordinator.isRefreshing(accessory.id), isFalse);
  });

  test('refreshing a different accessory is not blocked by one in flight', () async {
    var completerA = Completer<void>();
    var callCounts = <String, int>{};
    var coordinator = RefreshCoordinator((accessory, {force = false, showFeedback = true}) async {
      callCounts[accessory!.id] = (callCounts[accessory.id] ?? 0) + 1;
      if (accessory.id == 'a') {
        await completerA.future;
      }
    });

    var futureA = coordinator.refresh(_accessory('a'));
    await coordinator.refresh(_accessory('b'));

    expect(callCounts['b'], 1);
    expect(coordinator.isRefreshing('a'), isTrue);
    expect(coordinator.isRefreshing('b'), isFalse);

    completerA.complete();
    await futureA;
    expect(coordinator.isRefreshing('a'), isFalse);
  });

  test('a throwing refresh still clears the in-flight flag', () async {
    var coordinator = RefreshCoordinator((accessory, {force = false, showFeedback = true}) async {
      throw Exception('boom');
    });
    var accessory = _accessory('a');

    await expectLater(coordinator.refresh(accessory), throwsException);

    expect(coordinator.isRefreshing(accessory.id), isFalse);
  });

  test('notifies listeners when the in-flight set changes', () async {
    var completer = Completer<void>();
    var coordinator = RefreshCoordinator(
      (accessory, {force = false, showFeedback = true}) => completer.future,
    );
    var accessory = _accessory('a');
    var notifications = 0;
    coordinator.addListener(() => notifications++);

    var future = coordinator.refresh(accessory);
    expect(notifications, 1);

    completer.complete();
    await future;
    expect(notifications, 2);
  });
}
