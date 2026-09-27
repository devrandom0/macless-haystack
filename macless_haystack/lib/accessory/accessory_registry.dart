import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';
import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/secure_storage_upgrade.dart';
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/findMy/find_my_controller.dart';
import 'package:macless_haystack/findMy/models.dart';
import 'package:macless_haystack/findMy/reports_fetcher.dart' show AppleSessionExpiredException;
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:macless_haystack/notifications/battery_notification_service.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';

const accessoryStorageKey = 'ACCESSORIES';
const historyStorageKey = 'HISTORY';

/// The entries in [result] that are still within [retentionDays] of now -
/// anything older is dropped. [_storeHistory] calls this with
/// `max(7, numberOfDaysToFetch)`, so raising the setting only ever grows
/// local retention - it never shrinks below the original 7-day floor.
List<Pair<dynamic, dynamic>> withinRetentionWindow(
  List<Pair<dynamic, dynamic>> result,
  int retentionDays,
) {
  var nowMinusDays = DateTime.now().subtract(Duration(days: retentionDays));
  var upperDayLimit = DateTime(
    nowMinusDays.year,
    nowMinusDays.month,
    nowMinusDays.day,
  );
  return result.where((element) => element.end.isAfter(upperDayLimit)).toList();
}

/// How many of [reports] are new to [accessory] - i.e. not already in its
/// persisted decrypted-hash set (see [Accessory.containsHash]).
///
/// This, not the server's own live-fetch-vs-cache bookkeeping, is what
/// answers "is there anything here I haven't already seen": the app's own
/// automatic startup fetch and the server's background history archiver
/// both independently mark reports as known server-side, so by the time a
/// user taps refresh the server very often has nothing left to call
/// "freshly fetched" even though the report is still new to this client.
/// Read-only - marking hashes as seen is [fillLocationHistory]'s job.
int countNewReports(List<FindMyLocationReport> reports, Accessory accessory) {
  return reports.where((r) => !accessory.containsHash(r.hash)).length;
}

/// Combines each accessory's own fetch result (in the same order as
/// [accessories]) into the batch-level new-report count and the shared
/// apple-session-stale signal.
///
/// [appleSessionStale] is null when nothing in the batch had an opinion -
/// no accessories were fetched at all, or every result came from an older
/// server - and otherwise true if any accessory's own result said so
/// (it's one shared server-side session, not a per-accessory one).
({int newCount, bool? appleSessionStale}) combineLocationReportResults(
  List<ComputedLocationReports> reportsForAccessories,
  Iterable<Accessory> accessories,
) {
  int newCount = 0;
  for (var i = 0; i < reportsForAccessories.length; i++) {
    newCount += countNewReports(
      reportsForAccessories[i].reports,
      accessories.elementAt(i),
    );
  }
  var opinions = reportsForAccessories
      .map((result) => result.appleSessionStale)
      .whereType<bool>();
  var appleSessionStale = opinions.isEmpty
      ? null
      : opinions.any((stale) => stale);
  return (newCount: newCount, appleSessionStale: appleSessionStale);
}

/// Runs [compute], folding a thrown [AppleSessionExpiredException] into
/// the same non-throwing result shape every other accessory's fetch
/// returns - one accessory hitting the no-cache-fallback case must not
/// make [Future.wait] abort the whole batch (or leak a raw exception past
/// callers that only expect the report data itself to fail).
Future<ComputedLocationReports> catchingExpiredAppleSession(
  Future<ComputedLocationReports> Function() compute,
) async {
  try {
    return await compute();
  } on AppleSessionExpiredException {
    return (
      reports: <FindMyLocationReport>[],
      newCount: 0,
      appleSessionStale: true,
    );
  }
}

class AccessoryRegistry extends ChangeNotifier {
  var _storage = const FlutterSecureStorage();
  List<Accessory> _accessories = [];
  bool loading = false;
  bool initialLoadFinished = false;

  /// Set once [checkStorageUpgradeStatus] has run. A non-null
  /// [secureStorageUpgradeWarning] means keys were lost to the
  /// flutter_secure_storage v11 cipher/backend removals.
  SecureStorageUpgradeStatus? storageUpgradeStatus;

  var logger = Logger(printer: PrettyPrinter(methodCount: 0));

  /// Creates the accessory registry.
  ///
  /// This is used to manage the accessories of the user.
  AccessoryRegistry() : super();

  /// A list of the user's accessories.
  UnmodifiableListView<Accessory> get accessories =>
      UnmodifiableListView(_accessories);

  /// Every tag currently used by at least one accessory, for autocomplete
  /// suggestions and the tag management screen. Derived, not stored -
  /// there's no tag that exists independently of the accessories using it.
  Set<String> get allTags =>
      accessories.expand((accessory) => accessory.tags).toSet();

  final Set<String> _activeTagFilter = {};

  /// Tags currently selected to filter accessory views by. Empty means no
  /// filter - every accessory matches. Session-only (not persisted).
  /// Intersected with [allTags] so a tag renamed or deleted elsewhere
  /// (e.g. via the tag management screen) can't leave a stale, invisible
  /// filter value silently hiding everything with no chip left to clear it.
  Set<String> get activeTagFilter => _activeTagFilter.intersection(allTags);

  /// Toggles [tag] in or out of the active tag filter and notifies listeners.
  void toggleTagFilter(String tag) {
    if (_activeTagFilter.contains(tag)) {
      _activeTagFilter.remove(tag);
    } else {
      _activeTagFilter.add(tag);
    }
    notifyListeners();
  }

  /// Loads the user's accessories from persistent storage.
  Future<void> loadAccessories() async {
    loading = true;

    String? serialized;

    try {
      serialized = await _storage.read(key: accessoryStorageKey);
    } catch (e) {
      serialized = null;
    }

    if (serialized != null) {
      List accessoryJson = json.decode(serialized);
      List<Accessory> loadedAccessories = accessoryJson
          .map((val) => Accessory.fromJson(val))
          .toList();
      _accessories = loadedAccessories;
      clearInvalidAccessories(_accessories);
      if (_accessories.length != loadedAccessories.length) {
        _storeAccessories();
      }
    } else {
      _accessories = [];
    }
    await loadHistory();

    loading = false;

    notifyListeners();
  }

  set setStorage(FlutterSecureStorage s) {
    _storage = s;
  }

  BatteryNotificationService _batteryNotificationService =
      BatteryNotificationService();
  bool Function() _isLowBatteryNotificationsEnabled = () =>
      Settings.getValue<bool>(lowBatteryNotificationsEnabledKey,
          defaultValue: true) ??
      true;

  /// Overrides the notification service - used by [main] to wire in the
  /// app's single shared instance, and by tests to inject a fake.
  set setBatteryNotificationService(BatteryNotificationService service) {
    _batteryNotificationService = service;
  }

  /// Test-only seam: overrides the real settings-backed enabled check.
  set setLowBatteryNotificationsEnabledCheck(bool Function() check) {
    _isLowBatteryNotificationsEnabled = check;
  }

  /// Notifies about [accessory]'s current [Accessory.lastBatteryStatus] if
  /// it just became low-or-worse for the first time, or escalated to a
  /// more severe low state, since the last time we notified. Resets the
  /// "already notified" marker once the battery reports a known-good
  /// status (`ok`/`medium`), so a later drop notifies again - a missing or
  /// unreadable reading (`null`/`unknown`) is left alone, since that's not
  /// a real recovery. See
  /// docs/superpowers/specs/2026-09-15-low-battery-notifications-design.md.
  Future<void> _maybeNotifyBatteryChange(Accessory accessory) async {
    if (!_isLowBatteryNotificationsEnabled()) return;

    var status = accessory.lastBatteryStatus;
    if (status == AccessoryBatteryStatus.ok ||
        status == AccessoryBatteryStatus.medium) {
      // A known-good reading is a real recovery - clear the marker so a
      // later drop notifies again.
      accessory.lastNotifiedBatteryStatus = null;
      return;
    }
    if (!isLowOrWorse(status)) {
      // null or unknown: no reliable battery data right now. Leave the
      // "already notified" marker untouched rather than treating a
      // missing reading as a recovery - that would silently re-arm and
      // re-notify on the next low reading even though nothing about the
      // battery actually improved.
      return;
    }

    if (isMoreSevere(accessory.lastNotifiedBatteryStatus, status!)) {
      await _batteryNotificationService.notifyLowBattery(accessory);
      accessory.lastNotifiedBatteryStatus = status;
    }
  }

  /// Checks whether the flutter_secure_storage v11 upgrade left any stored
  /// keys unreadable and logs a warning when it did. Run once at startup,
  /// separately from [loadAccessories], since for this app a lost private
  /// key means the accessory becomes permanently untrackable.
  Future<SecureStorageUpgradeStatus> checkStorageUpgradeStatus() async {
    SecureStorageUpgradeStatus status;
    try {
      status = await _storage.checkUpgradeStatus();
    } on PlatformException catch (e) {
      // The plugin's own MissingPluginException handling already covers an
      // unimplemented platform; this is for everything else a native side
      // can throw (e.g. a failed keystore read) so it becomes a logged
      // failure instead of an unhandled zone error.
      logger.w('Could not check secure storage upgrade status: $e');
      status = SecureStorageUpgradeStatus.unsupported;
    }
    storageUpgradeStatus = status;
    final warning = secureStorageUpgradeWarning(status);
    if (warning != null) {
      logger.w(warning);
    }
    notifyListeners();
    return status;
  }

  Future<void> loadHistory() async {
    String? history = await _storage.read(key: historyStorageKey);
    if (history != null) {
      Map<String, dynamic> jsonDecoded = jsonDecode(history);
      for (var item in _accessories) {
        var currElement = jsonDecoded[item.id];
        if (currElement != null) {
          item.addLocationHistory(currElement);
        }
      }
    }
  }

  /// Fetches one accessory's reports (its own key plus any additional
  /// keys) via [FindMyController]. Test-only seam: the real implementation
  /// goes through that class's static, platform-backed secure storage
  /// reads and an isolate-spawning `compute()` call, neither of which a
  /// plain unit test can fake directly.
  Future<ComputedLocationReports> Function(
    Accessory accessory,
    String? url, {
    required bool force,
  })
  _fetchReportsForAccessory = _defaultFetchReportsForAccessory;

  set setFetchReportsForAccessory(
    Future<ComputedLocationReports> Function(
      Accessory accessory,
      String? url, {
      required bool force,
    })
    fetch,
  ) {
    _fetchReportsForAccessory = fetch;
  }

  static Future<ComputedLocationReports> _defaultFetchReportsForAccessory(
    Accessory accessory,
    String? url, {
    required bool force,
  }) async {
    var keyPair = await FindMyController.getKeyPair(accessory.hashedPublicKey);

    List<FindMyKeyPair> hashedPublicKeys =
        await Stream.fromIterable(accessory.additionalKeys)
            .asyncMap(
              (hashedPublicKey) => FindMyController.getKeyPair(hashedPublicKey),
            )
            .toList();

    hashedPublicKeys.add(keyPair);

    return catchingExpiredAppleSession(
      () => FindMyController.computeResults(hashedPublicKeys, url, force: force),
    );
  }

  /// Fetches new location reports and matches them to their accessory.
  ///
  /// Returns how many reports are genuinely new data, not just the total
  /// size of whatever was returned (which may be entirely already-known
  /// cached reports), plus whether the server's Apple session is stale
  /// (see [combineLocationReportResults] - null when nothing in the batch
  /// had an opinion, e.g. no active accessories or an older server).
  /// [force] bypasses the endpoint's freshness cache and asks Apple
  /// directly.
  Future<({int newCount, bool? appleSessionStale})> loadLocationReports(
    Iterable<Accessory> currentAccessories, {
    bool force = false,
  }) async {
    List<Future<ComputedLocationReports>> runningLocationRequests = [];

    // request location updates for all accessories simultaneously
    String? url = Settings.getValue<String>(endpointUrl);
    for (var i = 0; i < currentAccessories.length; i++) {
      var accessory = currentAccessories.elementAt(i);
      runningLocationRequests.add(
        _fetchReportsForAccessory(accessory, url, force: force),
      );
    }

    var reportsForAccessories = await Future.wait(runningLocationRequests);
    var combined = combineLocationReportResults(
      reportsForAccessories,
      currentAccessories,
    );
    var retentionDays =
        Settings.getValue<int>(numberOfDaysToFetch, defaultValue: 7) ?? 7;
    Map<Accessory, Future<List<Pair<dynamic, dynamic>>>> historyEntries = {};
    for (var i = 0; i < currentAccessories.length; i++) {
      var accessory = currentAccessories.elementAt(i);
      var reports = reportsForAccessories.elementAt(i).reports;
      logger.i(
        '${reports.length} reports fetched for ${accessory.hashedPublicKey} in total',
      );

      if (reports.where((element) => !element.isEncrypted()).isNotEmpty) {
        var lastReport = reports
            .where((element) => !element.isEncrypted())
            .first;
        var reportDate =
            lastReport.timestamp ?? DateTime.fromMicrosecondsSinceEpoch(0);
        if (accessory.datePublished != null &&
            reportDate.isAfter(accessory.datePublished!)) {
          accessory.datePublished = reportDate;
          accessory.lastLocation = LatLng(
            lastReport.latitude!,
            lastReport.longitude!,
          );

          // Update last battery status
          accessory.lastBatteryStatus = lastReport.batteryStatus;
          await _maybeNotifyBatteryChange(accessory);
          accessory.hasChangedFlag = true;
        }
      }
      historyEntries[accessory] = fillLocationHistory(
        reports,
        accessory,
        retentionDays: retentionDays,
      ).catchError((Object error, StackTrace stackTrace) {
        // One accessory's history failing (e.g. a bad decrypt) must not
        // stop _storeHistory below from persisting every other
        // accessory's, nor make the awaited call throw and abort the
        // whole refresh - it's now awaited, so an uncaught error here
        // would do both instead of just skipping this one entry.
        logger.e(
          'Error filling location history for ${accessory.id}',
          error: error,
          stackTrace: stackTrace,
        );
        return accessory.locationHistory;
      });
    }
    // Store updated lastLocation and datePublished for accessories
    _storeAccessories();

    // Awaited so locationHistory is actually populated - fillLocationHistory
    // mutates it before resolving - by the time this method returns. Left
    // as fire-and-forget, a caller (or the UI right after) could see stale
    // data because the refresh had "finished" before this settled.
    await _storeHistory(historyEntries, retentionDays);

    initialLoadFinished = true;
    notifyListeners();
    return combined;
  }

  Future<void> _storeHistory(
    Map<Accessory, Future<List<Pair<dynamic, dynamic>>>> historyEntries,
    int retentionDays,
  ) async {
    Map<String, List<Pair<dynamic, dynamic>>> historyEntriesAsJson = {};
    var effectiveRetentionDays = max(7, retentionDays);
    for (var entry in historyEntries.entries) {
      Accessory key = entry.key;
      Future<List<Pair<dynamic, dynamic>>> future = entry.value;
      List<Pair<dynamic, dynamic>> result = await future;
      var filtered = withinRetentionWindow(result, effectiveRetentionDays);
      if (filtered.length != result.length) {
        logger.i(
          '${result.length - filtered.length} history elements have been filtered out and will be deleted due to age.',
        );
      }
      historyEntriesAsJson[key.id] = filtered;
    }
    //find all accessories not in list (inactive or single item refresh)
    accessories
        .where((a) => !historyEntriesAsJson.keys.toList().contains(a.id))
        .forEach((a) {
          historyEntriesAsJson[a.id] = a.locationHistory;
        });

    var historyJson = jsonEncode(historyEntriesAsJson);
    _storage.write(key: historyStorageKey, value: historyJson);
  }

  /// Stores the user's accessories in persistent storage.
  Future<void> _storeAccessories() async {
    List jsonList = _accessories.map(jsonEncode).toList();
    await _storage.write(key: accessoryStorageKey, value: jsonList.toString());
  }

  /// Adds a new accessory to this registry.
  void addAccessory(Accessory accessory) {
    Accessory? foundOne;
    for (var acc in _accessories) {
      if (accessory.hashedPublicKey == acc.hashedPublicKey) {
        foundOne = acc;
        break; // There is already one with this id
      }
    }
    if (foundOne != null) {
      _accessories.remove(foundOne);
    }

    _accessories.add(accessory);
    _storeAccessories();
    notifyListeners();
  }

  /// Removes [accessory] from this registry.
  void removeAccessory(Accessory accessory) {
    _accessories.remove(accessory);
    accessory.getHashedPublicKey().then((publicKey) {
      _storage.delete(key: publicKey);
    });

    _storeAccessories();
    notifyListeners();
  }

  Future<List<Pair<dynamic, dynamic>>> fillLocationHistory(
    List<FindMyLocationReport> reports,
    Accessory accessory, {
    int? retentionDays,
  }) async {
    List<FindMyLocationReport> decryptedReports = [];
    //Decrypt only reports that are not already decrypted
    Set<String> hashes = {};
    int count = 0;
    //This will be achieved by saving the hash(payload) of all already decrypted reports
    for (var i = 0; i < reports.length; i++) {
      var currHash = reports[i].hash;
      if (!accessory.containsHash(currHash)) {
        accessory.addDecryptedHash(currHash);
        logger.d('Decrypting report $i of ${reports.length} with id $currHash');
        await reports[i].decrypt();
        decryptedReports.add(reports[i]);
      } else {
        count++;
      }

      hashes.add(currHash!);
    }
    logger.d(
      '${reports.length - count} reports decrypted. Decryption of $count reports skipped, because they are already fetched and decrypted.',
    );
    //All hashes, that are not in the reports anymore can be deleted, because they are out of time
    accessory.removeOldHashes(retentionDays: retentionDays ?? 7);
    //Sort by date
    decryptedReports.sort((a, b) {
      var aDate = a.timestamp ?? DateTime(1970);
      var bDate = b.timestamp ?? DateTime(1970);
      return aDate.compareTo(bDate);
    });

    //Update the latest timestamp
    if (decryptedReports.isNotEmpty) {
      var lastReport = decryptedReports[decryptedReports.length - 1];
      var oldTs = accessory.datePublished;
      var latestReportTS = lastReport.timestamp ?? DateTime(1971);

      if (oldTs == null || oldTs.isBefore(latestReportTS)) {
        //only an actualization if oldTS is not set or is older than the latest of the new ones
        accessory.lastLocation = LatLng(
          lastReport.latitude!,
          lastReport.longitude!,
        );
        accessory.datePublished = latestReportTS;

        //Update alway battery status
        accessory.lastBatteryStatus = lastReport.batteryStatus;
        await _maybeNotifyBatteryChange(accessory);

        accessory.hasChangedFlag = true;

        notifyListeners(); //redraw the UI, if the timestamp has changed
      }
    }

    //add to history in correct order
    for (var i = 0; i < decryptedReports.length; i++) {
      FindMyLocationReport report = decryptedReports[i];
      if (report.longitude!.abs() <= 180 && report.latitude!.abs() <= 90) {
        accessory.addLocationHistoryEntry(report);
      } else {
        logger.d(
          'Report skipped, because of anomaly data (lat: ${report.latitude}, lon: ${report.longitude}, acc: ${report.accuracy})',
        );
      }
    }
    _storeAccessories();
    return accessory.locationHistory;
  }

  /// Updates [oldAccessory] with the values from [newAccessory].
  void editAccessory(Accessory oldAccessory, Accessory newAccessory) {
    oldAccessory.update(newAccessory);
    _storeAccessories();
    notifyListeners();
  }

  void clearInvalidAccessories(List<Accessory> loadedAccessories) async {
    List<int> indicesToRemove = [];
    for (int i = 0; i < accessories.length; i++) {
      bool containsKey = await _storage.containsKey(
        key: accessories[i].hashedPublicKey,
      );
      if (!containsKey) {
        // Invalid Element should be removed
        indicesToRemove.add(i);
      }
    }
    for (int index in indicesToRemove.reversed) {
      loadedAccessories.removeAt(index);
    }
  }

  void deleteData(Accessory accessory) {
    accessory.lastBatteryStatus = null;
    accessory.lastNotifiedBatteryStatus = null;
    accessory.lastLocation = null;
    accessory.hashesWithTS.clear();
    accessory.datePublished = DateTime(1970);
    accessory.place = Future.value(null);
    accessory.locationHistory.clear();
    _removeHistoryEntry(accessory);
    _storeAccessories();
    notifyListeners();
  }

  Future<void> _removeHistoryEntry(Accessory accessoryToRemove) async {
    String? history = await _storage.read(key: historyStorageKey);
    if (history == null || history.isEmpty) {
      return;
    }
    Map<String, dynamic> historyMap = jsonDecode(history);

    historyMap.remove(accessoryToRemove.id);

    await _storage.write(key: historyStorageKey, value: jsonEncode(historyMap));
  }

  void saveOrderUpdates(List<Accessory> newOrder) {
    final Map<Accessory, int> positionMap = {
      for (int i = 0; i < newOrder.length; i++) newOrder[i]: i,
    };
    // An accessory missing from newOrder (e.g. a registry change racing a
    // pending reorder) sorts to the end instead of throwing.
    _accessories.sort(
      (a, b) => (positionMap[a] ?? newOrder.length).compareTo(
        positionMap[b] ?? newOrder.length,
      ),
    );
    _storeAccessories();
    notifyListeners();
  }
}
