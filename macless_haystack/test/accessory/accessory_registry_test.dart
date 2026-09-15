import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/findMy/models.dart';
import 'package:macless_haystack/location/location_model.dart';
import 'package:macless_haystack/notifications/battery_notification_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'accessory_registry_test.mocks.dart';

// class MockLocationModel extends Mock implements LocationModel {}

@GenerateMocks([LocationModel, FlutterSecureStorage, BatteryNotificationService])
void main() {
  var locationModel = MockLocationModel();
  var registry = AccessoryRegistry();
  Accessory accessory = Accessory(
    id: '',
    name: '',
    hashedPublicKey: '',
    datePublished: null,
    hashesWithTS: {},
    locationHistory: [],
    lastBatteryStatus: null,
    additionalKeys: List.empty(),
  );
  setUp(() {
    when(
      locationModel.getAddress(any),
    ).thenAnswer((_) async => const Placemark());
    registry.setStorage = MockFlutterSecureStorage();
    registry.setBatteryNotificationService = MockBatteryNotificationService();
    // Settings.init() is never called in this test file, so the real
    // Settings-backed default would assert; every test needs this stubbed
    // regardless of whether it touches battery status.
    registry.setLowBatteryNotificationsEnabledCheck = () => true;
    accessory.locationModel = locationModel;
    accessory.locationHistory.clear();
    accessory.datePublished = null;
  });

  test(
    'Add location history same location unsorted with no entries before',
    () async {
      List<FindMyLocationReport> reports = [];
      // 8 o'clock
      reports.add(
        FindMyLocationReport.withHash(
          1,
          2,
          DateTime(2024, 1, 1, 8, 0, 0),
          DateTime.now().microsecondsSinceEpoch.toString(),
        ),
      );
      //6 o'clock
      reports.add(
        FindMyLocationReport.withHash(
          1,
          2,
          DateTime(2024, 1, 1, 6, 0, 0),
          DateTime.now().microsecondsSinceEpoch.toString(),
        ),
      );
      //10 o'clock
      reports.add(
        FindMyLocationReport.withHash(
          1,
          2,
          DateTime(2024, 1, 1, 10, 0, 0),
          DateTime.now().microsecondsSinceEpoch.toString(),
        ),
      );

      await registry.fillLocationHistory(reports, accessory);
      var latest = accessory.latestHistoryEntry();
      expect(DateTime(2024, 1, 1, 10, 0, 0), latest);
      expect(1, accessory.locationHistory.length);
      expect(
        DateTime(2024, 1, 1, 10, 0, 0),
        accessory.locationHistory.elementAt(0).end,
      );
      expect(
        DateTime(2024, 1, 1, 6, 0, 0),
        accessory.locationHistory.elementAt(0).start,
      );
    },
  );

  test(
    'Add location history different location unsorted with no entries before',
    () async {
      await fillDefaultLocations(registry, accessory);
      var locationHistory = accessory.locationHistory;
      expect(3, locationHistory.length);

      var latest = accessory.datePublished;
      var lastLocation = accessory.lastLocation;
      var endOfFirstEntry = accessory.latestHistoryEntry();

      expect(endOfFirstEntry, DateTime(2024, 1, 1, 9, 0, 0));
      expect(latest, DateTime(2024, 1, 1, 12, 0, 0));
      expect(lastLocation, const LatLng(1, 2));

      expect(locationHistory.elementAt(0).start, DateTime(2024, 1, 1, 8, 0, 0));
      expect(locationHistory.elementAt(0).end, DateTime(2024, 1, 1, 9, 0, 0));

      expect(
        locationHistory.elementAt(1).start,
        DateTime(2024, 1, 1, 10, 0, 0),
      );
      expect(locationHistory.elementAt(1).end, DateTime(2024, 1, 1, 10, 0, 0));

      expect(
        locationHistory.elementAt(2).start,
        DateTime(2024, 1, 1, 12, 0, 0),
      );
      expect(locationHistory.elementAt(2).end, DateTime(2024, 1, 1, 12, 0, 0));
    },
  );

  test(
    'Add same location entries twice should not change latest anything',
    () async {
      List<FindMyLocationReport> reports = await fillDefaultLocations(
        registry,
        accessory,
      );
      reports.shuffle();
      await registry.fillLocationHistory(reports, accessory);
      var locationHistory = accessory.locationHistory;
      expect(3, locationHistory.length);

      var latest = accessory.datePublished;
      var lastLocation = accessory.lastLocation;
      var endOfFirstEntry = accessory.latestHistoryEntry();

      expect(endOfFirstEntry, DateTime(2024, 1, 1, 9, 0, 0));
      expect(latest, DateTime(2024, 1, 1, 12, 0, 0));
      expect(lastLocation, const LatLng(1, 2));

      expect(locationHistory.elementAt(0).start, DateTime(2024, 1, 1, 8, 0, 0));
      expect(locationHistory.elementAt(0).end, DateTime(2024, 1, 1, 9, 0, 0));

      expect(
        locationHistory.elementAt(1).start,
        DateTime(2024, 1, 1, 10, 0, 0),
      );
      expect(locationHistory.elementAt(1).end, DateTime(2024, 1, 1, 10, 0, 0));

      expect(
        locationHistory.elementAt(2).start,
        DateTime(2024, 1, 1, 12, 0, 0),
      );
      expect(locationHistory.elementAt(2).end, DateTime(2024, 1, 1, 12, 0, 0));
    },
  );

  test(
    'Add same location at the end should expand and change latestLocationTimestamp',
    () async {
      List<FindMyLocationReport> reports = await fillDefaultLocations(
        registry,
        accessory,
      );
      reports.clear();
      reports.add(
        FindMyLocationReport.withHash(
          1,
          2,
          DateTime(2024, 1, 2, 8, 0, 0),
          DateTime.now().microsecondsSinceEpoch.toString(),
        ),
      );
      await registry.fillLocationHistory(reports, accessory);
      var locationHistory = accessory.locationHistory;
      expect(3, locationHistory.length);

      var latest = accessory.datePublished;
      var lastLocation = accessory.lastLocation;
      var endOfFirstEntry = accessory.latestHistoryEntry();

      expect(endOfFirstEntry, DateTime(2024, 1, 1, 9, 0, 0));
      expect(latest, DateTime(2024, 1, 2, 8, 0, 0));
      expect(lastLocation, const LatLng(1, 2));

      expect(
        locationHistory.elementAt(2).start,
        DateTime(2024, 1, 1, 12, 0, 0),
      );
      expect(locationHistory.elementAt(2).end, DateTime(2024, 1, 2, 8, 0, 0));
    },
  );

  test('Add same location in the middle should not change anything', () async {
    List<FindMyLocationReport> reports = await fillDefaultLocations(
      registry,
      accessory,
    );
    reports.clear();
    reports.add(
      FindMyLocationReport.withHash(
        1,
        2,
        DateTime(2024, 1, 1, 8, 30, 0),
        DateTime.now().microsecondsSinceEpoch.toString(),
      ),
    );
    await registry.fillLocationHistory(reports, accessory);
    var locationHistory = accessory.locationHistory;
    expect(3, locationHistory.length);

    var latest = accessory.datePublished;
    var lastLocation = accessory.lastLocation;
    var endOfFirstEntry = accessory.latestHistoryEntry();

    expect(endOfFirstEntry, DateTime(2024, 1, 1, 9, 0, 0));
    expect(latest, DateTime(2024, 1, 1, 12, 0, 0));
    expect(lastLocation, const LatLng(1, 2));

    expect(locationHistory.elementAt(2).start, DateTime(2024, 1, 1, 12, 0, 0));
    expect(locationHistory.elementAt(2).end, DateTime(2024, 1, 1, 12, 0, 0));
  });

  test('Add other location in the middle should split entries', () async {
    List<FindMyLocationReport> reports = await fillDefaultLocations(
      registry,
      accessory,
    );
    reports.clear();
    reports.add(
      FindMyLocationReport.withHash(
        4,
        5,
        DateTime(2024, 1, 1, 8, 30, 0),
        DateTime.now().microsecondsSinceEpoch.toString(),
      ),
    );
    await registry.fillLocationHistory(reports, accessory);
    var locationHistory = accessory.getSortedLocationHistory();
    expect(5, locationHistory.length);

    var latest = accessory.datePublished;
    var lastLocation = accessory.lastLocation;
    var endOfFirstEntry = accessory.latestHistoryEntry();

    expect(endOfFirstEntry, DateTime(2024, 1, 1, 8, 0, 0));
    expect(latest, DateTime(2024, 1, 1, 12, 0, 0));
    expect(lastLocation, const LatLng(1, 2));

    expect(locationHistory.elementAt(1).start, DateTime(2024, 1, 1, 8, 30, 0));
    expect(locationHistory.elementAt(1).end, DateTime(2024, 1, 1, 8, 30, 0));
    expect(locationHistory.elementAt(2).start, DateTime(2024, 1, 1, 9, 0, 0));
    expect(locationHistory.elementAt(2).end, DateTime(2024, 1, 1, 9, 0, 0));
  });

  test(
    'Add location at time already exist will be skipped because of invalid data',
    () async {
      List<FindMyLocationReport> reports = await fillDefaultLocations(
        registry,
        accessory,
      );
      reports.clear();
      reports.add(
        FindMyLocationReport.withHash(
          4,
          5,
          DateTime(2024, 1, 1, 8, 0, 0),
          DateTime.now().microsecondsSinceEpoch.toString(),
        ),
      );

      reports.add(
        FindMyLocationReport.withHash(
          4,
          5,
          DateTime(2024, 1, 1, 9, 0, 0),
          DateTime.now().microsecondsSinceEpoch.toString(),
        ),
      );
      await registry.fillLocationHistory(reports, accessory);
      var locationHistory = accessory.getSortedLocationHistory();
      expect(3, locationHistory.length);

      var latest = accessory.datePublished;
      var lastLocation = accessory.lastLocation;
      var endOfFirstEntry = accessory.latestHistoryEntry();

      expect(endOfFirstEntry, DateTime(2024, 1, 1, 9, 0, 0));
      expect(latest, DateTime(2024, 1, 1, 12, 0, 0));
      expect(lastLocation, const LatLng(1, 2));
      // Invalid locations added, but first location has not changed
      expect(locationHistory.elementAt(0).location.latitude, 1);
      expect(locationHistory.elementAt(0).location.longitude, 2);
      expect(locationHistory.elementAt(0).start, DateTime(2024, 1, 1, 8, 0, 0));
    },
  );

  test(
    'Add other location at the end should create new entry and change latestLocationTimestamp',
    () async {
      List<FindMyLocationReport> reports = await fillDefaultLocations(
        registry,
        accessory,
      );
      reports.clear();
      reports.add(
        FindMyLocationReport.withHash(
          1,
          3,
          DateTime(2024, 1, 2, 8, 0, 0),
          DateTime.now().microsecondsSinceEpoch.toString(),
        ),
      );
      await registry.fillLocationHistory(reports, accessory);
      var locationHistory = accessory.locationHistory;
      expect(4, locationHistory.length);

      var latest = accessory.datePublished;
      var lastLocation = accessory.lastLocation;
      var endOfFirstEntry = accessory.latestHistoryEntry();

      expect(endOfFirstEntry, DateTime(2024, 1, 1, 9, 0, 0));
      expect(latest, DateTime(2024, 1, 2, 8, 0, 0));
      expect(lastLocation, const LatLng(1, 3));

      expect(locationHistory.elementAt(3).start, DateTime(2024, 1, 2, 8, 0, 0));
      expect(locationHistory.elementAt(3).end, DateTime(2024, 1, 2, 8, 0, 0));
    },
  );

  test('saveOrderUpdates does not throw when an accessory is missing from '
      'the new order', () {
    var a = Accessory(
      id: 'a',
      name: 'a',
      hashedPublicKey: 'hash-a',
      datePublished: null,
      hashesWithTS: {},
      locationHistory: [],
      lastBatteryStatus: null,
      additionalKeys: List.empty(),
    );
    var b = Accessory(
      id: 'b',
      name: 'b',
      hashedPublicKey: 'hash-b',
      datePublished: null,
      hashesWithTS: {},
      locationHistory: [],
      lastBatteryStatus: null,
      additionalKeys: List.empty(),
    );
    registry.addAccessory(a);
    registry.addAccessory(b);

    // b is missing from the new order - e.g. it was added by a concurrent
    // registry change while a reorder was in flight.
    expect(() => registry.saveOrderUpdates([a]), returnsNormally);
  });

  test('saveOrderUpdates notifies listeners', () {
    var a = Accessory(
      id: 'c',
      name: 'c',
      hashedPublicKey: 'hash-c',
      datePublished: null,
      hashesWithTS: {},
      locationHistory: [],
      lastBatteryStatus: null,
      additionalKeys: List.empty(),
    );
    registry.addAccessory(a);

    var notified = false;
    registry.addListener(() => notified = true);

    registry.saveOrderUpdates([a]);

    expect(notified, isTrue);
  });

  group('checkStorageUpgradeStatus', () {
    test('returns and stores the status the platform reports', () async {
      const status = SecureStorageUpgradeStatus(
        state: SecureStorageUpgradeState.legacyDataDiscarded,
        entryCount: 2,
      );
      var storage = MockFlutterSecureStorage();
      when(storage.checkUpgradeStatus()).thenAnswer((_) async => status);
      registry.setStorage = storage;

      final result = await registry.checkStorageUpgradeStatus();

      expect(result, status);
      expect(registry.storageUpgradeStatus, status);
    });

    test('does not throw when the platform side raises', () async {
      var storage = MockFlutterSecureStorage();
      when(
        storage.checkUpgradeStatus(),
      ).thenThrow(PlatformException(code: 'read_error'));
      registry.setStorage = storage;

      final result = await registry.checkStorageUpgradeStatus();

      expect(result, SecureStorageUpgradeStatus.unsupported);
      expect(
        registry.storageUpgradeStatus,
        SecureStorageUpgradeStatus.unsupported,
      );
    });
  });

  group('countNewReports', () {
    Accessory freshAccessory() => Accessory(
      id: '',
      name: '',
      hashedPublicKey: '',
      datePublished: null,
      hashesWithTS: {},
      locationHistory: [],
      lastBatteryStatus: null,
      additionalKeys: List.empty(),
    );

    test(
      'counts every report as new for an accessory with no known hashes',
      () {
        var acc = freshAccessory();
        var reports = [
          FindMyLocationReport.withHash(
            1,
            2,
            DateTime(2024, 1, 1),
            'hash-aaaa1',
          ),
          FindMyLocationReport.withHash(
            1,
            2,
            DateTime(2024, 1, 2),
            'hash-bbbb2',
          ),
        ];

        expect(countNewReports(reports, acc), 2);
      },
    );

    test('excludes reports whose hash the accessory already knows', () {
      var acc = freshAccessory();
      acc.addDecryptedHash('hash-aaaa1');
      var reports = [
        FindMyLocationReport.withHash(1, 2, DateTime(2024, 1, 1), 'hash-aaaa1'),
        FindMyLocationReport.withHash(1, 2, DateTime(2024, 1, 2), 'hash-bbbb2'),
      ];

      expect(countNewReports(reports, acc), 1);
    });

    test('is zero when every report was already known - the server '
        'reconfirming cached data a second automatic/background fetch '
        'already stored', () {
      var acc = freshAccessory();
      acc.addDecryptedHash('hash-aaaa1');
      acc.addDecryptedHash('hash-bbbb2');
      var reports = [
        FindMyLocationReport.withHash(1, 2, DateTime(2024, 1, 1), 'hash-aaaa1'),
        FindMyLocationReport.withHash(1, 2, DateTime(2024, 1, 2), 'hash-bbbb2'),
      ];

      expect(countNewReports(reports, acc), 0);
    });

    test('does not mutate the accessory - fillLocationHistory owns marking '
        'hashes as seen, this only counts', () {
      var acc = freshAccessory();
      var reports = [
        FindMyLocationReport.withHash(1, 2, DateTime(2024, 1, 1), 'hash-aaaa1'),
      ];

      countNewReports(reports, acc);

      expect(acc.containsHash('hash-aaaa1'), isFalse);
    });
  });

  group('low-battery notifications', () {
    late MockBatteryNotificationService mockNotificationService;

    setUp(() {
      mockNotificationService = MockBatteryNotificationService();
      registry.setBatteryNotificationService = mockNotificationService;
      // Every test in this group must control this explicitly rather than
      // falling through to the real Settings-backed default, since
      // Settings.init() is never called in this test file (confirmed: no
      // other test in it touches a Settings.getValue-backed codepath
      // either) and would throw/behave unpredictably if hit here.
      registry.setLowBatteryNotificationsEnabledCheck = () => true;
      when(mockNotificationService.notifyLowBattery(any))
          .thenAnswer((_) async {});
    });

    Accessory freshAccessory() => Accessory(
        id: 'battery-test',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: List.empty())
      ..locationModel = locationModel;

    FindMyLocationReport reportWithBattery(
      DateTime timestamp,
      AccessoryBatteryStatus? batteryStatus,
    ) {
      var report = FindMyLocationReport.withHash(
        1,
        2,
        timestamp,
        DateTime.now().microsecondsSinceEpoch.toString(),
      );
      report.batteryStatus = batteryStatus;
      return report;
    }

    test('ok battery does not notify', () async {
      var accessory = freshAccessory();

      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 1), AccessoryBatteryStatus.ok)],
        accessory,
      );

      verifyNever(mockNotificationService.notifyLowBattery(any));
    });

    test('first drop to low notifies once', () async {
      var accessory = freshAccessory();

      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 1), AccessoryBatteryStatus.low)],
        accessory,
      );

      verify(mockNotificationService.notifyLowBattery(accessory)).called(1);
      expect(accessory.lastNotifiedBatteryStatus, AccessoryBatteryStatus.low);
    });

    test('staying low does not re-notify', () async {
      var accessory = freshAccessory();
      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 1), AccessoryBatteryStatus.low)],
        accessory,
      );
      clearInteractions(mockNotificationService);

      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 2), AccessoryBatteryStatus.low)],
        accessory,
      );

      verifyNever(mockNotificationService.notifyLowBattery(any));
    });

    test('escalating from low to criticalLow notifies again', () async {
      var accessory = freshAccessory();
      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 1), AccessoryBatteryStatus.low)],
        accessory,
      );
      clearInteractions(mockNotificationService);

      await registry.fillLocationHistory(
        [
          reportWithBattery(
              DateTime(2026, 1, 2), AccessoryBatteryStatus.criticalLow)
        ],
        accessory,
      );

      verify(mockNotificationService.notifyLowBattery(accessory)).called(1);
      expect(accessory.lastNotifiedBatteryStatus,
          AccessoryBatteryStatus.criticalLow);
    });

    test('recovering to ok resets, so a later drop notifies again', () async {
      var accessory = freshAccessory();
      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 1), AccessoryBatteryStatus.low)],
        accessory,
      );
      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 2), AccessoryBatteryStatus.ok)],
        accessory,
      );
      expect(accessory.lastNotifiedBatteryStatus, isNull);
      clearInteractions(mockNotificationService);

      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 3), AccessoryBatteryStatus.low)],
        accessory,
      );

      verify(mockNotificationService.notifyLowBattery(accessory)).called(1);
    });

    test('a report with no battery data does not reset an existing alert',
        () async {
      var accessory = freshAccessory();
      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 1), AccessoryBatteryStatus.low)],
        accessory,
      );
      clearInteractions(mockNotificationService);

      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 2), null)],
        accessory,
      );

      expect(accessory.lastNotifiedBatteryStatus, AccessoryBatteryStatus.low);
      verifyNever(mockNotificationService.notifyLowBattery(any));

      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 3), AccessoryBatteryStatus.low)],
        accessory,
      );

      verifyNever(mockNotificationService.notifyLowBattery(any));
    });

    test('setting disabled suppresses notification', () async {
      registry.setLowBatteryNotificationsEnabledCheck = () => false;
      var accessory = freshAccessory();

      await registry.fillLocationHistory(
        [reportWithBattery(DateTime(2026, 1, 1), AccessoryBatteryStatus.low)],
        accessory,
      );

      verifyNever(mockNotificationService.notifyLowBattery(any));
      registry.setLowBatteryNotificationsEnabledCheck = () => true;
    });
  });

  test('deleteData resets lastNotifiedBatteryStatus', () {
    // deleteData fires off a history-storage read in the background;
    // stub it so that unrelated call doesn't surface as an unhandled
    // MissingStubError against this test.
    var storage = MockFlutterSecureStorage();
    when(storage.read(key: anyNamed('key'))).thenAnswer((_) async => null);
    registry.setStorage = storage;

    var accessory = Accessory(
        id: 'x',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: DateTime(1970),
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: AccessoryBatteryStatus.low,
        additionalKeys: List.empty())
      ..lastNotifiedBatteryStatus = AccessoryBatteryStatus.low;

    registry.deleteData(accessory);

    expect(accessory.lastNotifiedBatteryStatus, isNull);
  });
}

///
/// Create default entries
///  LAT  | Lon | start | end
///  1       2     8 - 9
///  2       2     10 - 10
///  1       2     12 - 12
///
Future<List<FindMyLocationReport>> fillDefaultLocations(
  AccessoryRegistry registry,
  Accessory accessory,
) async {
  List<FindMyLocationReport> reports = [];

  // 8 o'clock 1st location
  reports.add(
    FindMyLocationReport.withHash(
      1,
      2,
      DateTime(2024, 1, 1, 8, 0, 0),
      DateTime.now().microsecondsSinceEpoch.toString(),
    ),
  );
  //10 o'clock second location
  reports.add(
    FindMyLocationReport.withHash(
      2,
      2,
      DateTime(2024, 1, 1, 10, 0, 0),
      DateTime.now().microsecondsSinceEpoch.toString(),
    ),
  );
  // 9 o'clock first location
  reports.add(
    FindMyLocationReport.withHash(
      1,
      2,
      DateTime(2024, 1, 1, 9, 0, 0),
      DateTime.now().microsecondsSinceEpoch.toString(),
    ),
  );
  //12 o'clock 1st location
  reports.add(
    FindMyLocationReport.withHash(
      1,
      2,
      DateTime(2024, 1, 1, 12, 0, 0),
      DateTime.now().microsecondsSinceEpoch.toString(),
    ),
  );
  await registry.fillLocationHistory(reports, accessory);
  return reports;
}
