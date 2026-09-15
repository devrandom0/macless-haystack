# Low-Battery Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show an Android system notification the first time a tracked accessory's battery drops to `low` or `criticalLow`, tappable to jump to that accessory on the map, without re-notifying on every fetch while it stays low.

**Architecture:** A pure severity helper decides whether a battery-status change is notify-worthy; a small `BatteryNotificationService` wraps `flutter_local_notifications` to actually show the Android notification; the existing fetch flow in `AccessoryRegistry` calls into both at its two existing battery-status-update sites; a tiny shared `ValueNotifier` singleton connects "notification tapped" to "UI should jump there," consumed independently by the dashboard (switch tab) and the map/list widget (center the map).

**Tech Stack:** Flutter/Dart, `flutter_local_notifications`, `mockito` (already used in this repo's tests), `flutter_settings_screens` (already used for all other settings).

**Spec:** docs/superpowers/specs/2026-09-15-low-battery-notifications-design.md

## Global Constraints

- Android only. No changes for Linux desktop or Web builds.
- No background polling - notifications only fire as a side effect of an existing fetch (startup/manual/force refresh) while the app process is running.
- `unknown` battery status is never treated as low-or-worse or as "more severe" than anything - only `low` and `criticalLow` count.
- Notification copy (exact strings, from the spec):
  - `low`: title `'${accessory.name} battery is low'`, body `'Consider replacing or recharging its battery soon.'`
  - `criticalLow`: title `'${accessory.name} battery is critically low'`, body `'It may stop reporting its location soon.'`
- Settings key for the toggle: `lowBatteryNotificationsEnabledKey`, default `true`.
- Minimum Android SDK in this project is 24 (`android/app/build.gradle`), target/compile 36 - `flutter_local_notifications` must be added via `flutter pub add flutter_local_notifications` (not hand-typed into pubspec.yaml) so the resolved version is guaranteed compatible with this project's actual Flutter/Dart SDK constraint (`sdk: ">=3.12.0 <4.0.0"`, `flutter: ">=3.44.0"`).

---

### Task 1: Battery severity helpers

**Files:**
- Modify: `lib/accessory/accessory_battery.dart`
- Test: `test/accessory/accessory_battery_test.dart` (new)

**Interfaces:**
- Produces: `bool isLowOrWorse(AccessoryBatteryStatus? status)`, `bool isMoreSevere(AccessoryBatteryStatus? previous, AccessoryBatteryStatus status)` - both top-level functions in `lib/accessory/accessory_battery.dart`, used by Task 5.

- [ ] **Step 1: Write the failing tests**

Create `test/accessory/accessory_battery_test.dart`:

```dart
import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:test/test.dart';

void main() {
  group('isLowOrWorse', () {
    test('ok is not low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.ok), isFalse);
    });

    test('medium is not low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.medium), isFalse);
    });

    test('unknown is not low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.unknown), isFalse);
    });

    test('null is not low-or-worse', () {
      expect(isLowOrWorse(null), isFalse);
    });

    test('low is low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.low), isTrue);
    });

    test('criticalLow is low-or-worse', () {
      expect(isLowOrWorse(AccessoryBatteryStatus.criticalLow), isTrue);
    });
  });

  group('isMoreSevere', () {
    test('first alert (previous is null) is always more severe', () {
      expect(isMoreSevere(null, AccessoryBatteryStatus.low), isTrue);
      expect(isMoreSevere(null, AccessoryBatteryStatus.criticalLow), isTrue);
    });

    test('same severity is not more severe (no re-alert)', () {
      expect(
        isMoreSevere(
            AccessoryBatteryStatus.low, AccessoryBatteryStatus.low),
        isFalse,
      );
      expect(
        isMoreSevere(AccessoryBatteryStatus.criticalLow,
            AccessoryBatteryStatus.criticalLow),
        isFalse,
      );
    });

    test('escalating from low to criticalLow is more severe', () {
      expect(
        isMoreSevere(
            AccessoryBatteryStatus.low, AccessoryBatteryStatus.criticalLow),
        isTrue,
      );
    });

    test('de-escalating from criticalLow to low is not more severe', () {
      expect(
        isMoreSevere(
            AccessoryBatteryStatus.criticalLow, AccessoryBatteryStatus.low),
        isFalse,
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/accessory/accessory_battery_test.dart`
Expected: FAIL with "isLowOrWorse isn't defined" / "isMoreSevere isn't defined" compile errors.

- [ ] **Step 3: Implement the helpers**

In `lib/accessory/accessory_battery.dart`, add below the existing `enum AccessoryBatteryStatus` block (keep the existing enum and `AccessoryBatteryIcon` class exactly as they are):

```dart
/// Whether [status] represents a battery level worth alerting on.
///
/// [AccessoryBatteryStatus.unknown] is declared after [criticalLow] in the
/// enum but means "no data," not "worse than critical" - it must never be
/// treated as low-or-worse, so this checks the two real low states
/// explicitly rather than comparing by `Enum.index`.
bool isLowOrWorse(AccessoryBatteryStatus? status) {
  return status == AccessoryBatteryStatus.low ||
      status == AccessoryBatteryStatus.criticalLow;
}

/// Whether [status] is strictly more severe than [previous].
///
/// Only meaningful when [status] is low-or-worse; callers are expected to
/// have already checked that. [previous] is nullable to represent "never
/// alerted yet," which is always more severe than any low state.
bool isMoreSevere(
  AccessoryBatteryStatus? previous,
  AccessoryBatteryStatus status,
) {
  if (previous == null) return true;
  const severityOrder = {
    AccessoryBatteryStatus.low: 0,
    AccessoryBatteryStatus.criticalLow: 1,
  };
  return (severityOrder[status] ?? -1) > (severityOrder[previous] ?? -1);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/accessory/accessory_battery_test.dart`
Expected: PASS (10 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/accessory/accessory_battery.dart test/accessory/accessory_battery_test.dart
git commit -m "feat: add battery severity helpers for low-battery alerts"
```

---

### Task 2: `lastNotifiedBatteryStatus` field on Accessory

**Files:**
- Modify: `lib/accessory/accessory_model.dart`
- Test: `test/accessory/accessory_model_test.dart`

**Interfaces:**
- Consumes: `AccessoryBatteryStatus` enum (existing, from Task 1's file).
- Produces: `Accessory.lastNotifiedBatteryStatus` (nullable field, read/written directly by Task 5).

- [ ] **Step 1: Write the failing tests**

Add to `test/accessory/accessory_model_test.dart` (below the existing tests, same `buildAccessory` helper - extend it to accept the new field with a default of `null` so existing calls don't need updating):

```dart
  Accessory buildAccessoryWithBattery({
    AccessoryBatteryStatus? lastBatteryStatus,
    AccessoryBatteryStatus? lastNotifiedBatteryStatus,
  }) {
    final accessory = Accessory(
        id: '1',
        name: 'Test',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: lastBatteryStatus,
        additionalKeys: List.empty());
    accessory.lastNotifiedBatteryStatus = lastNotifiedBatteryStatus;
    return accessory;
  }

  test('toJson/fromJson round-trips lastNotifiedBatteryStatus when set', () {
    final accessory = buildAccessoryWithBattery(
      lastBatteryStatus: AccessoryBatteryStatus.low,
      lastNotifiedBatteryStatus: AccessoryBatteryStatus.low,
    );

    final restored = Accessory.fromJson(accessory.toJson());

    expect(restored.lastNotifiedBatteryStatus, AccessoryBatteryStatus.low);
  });

  test('toJson omits lastNotifiedBatteryStatus when null', () {
    final accessory = buildAccessoryWithBattery();

    expect(accessory.toJson().containsKey('lastNotifiedBatteryStatus'), isFalse);
  });

  test('fromJson leaves lastNotifiedBatteryStatus null when absent', () {
    final accessory = buildAccessoryWithBattery();

    final restored = Accessory.fromJson(accessory.toJson());

    expect(restored.lastNotifiedBatteryStatus, isNull);
  });

  test('clone copies lastNotifiedBatteryStatus', () {
    final accessory = buildAccessoryWithBattery(
      lastNotifiedBatteryStatus: AccessoryBatteryStatus.criticalLow,
    );

    final cloned = accessory.clone();

    expect(cloned.lastNotifiedBatteryStatus, AccessoryBatteryStatus.criticalLow);
  });
```

`test/accessory/accessory_model_test.dart` currently imports only `accessory_model.dart` (confirmed: no import of `accessory_battery.dart`), so also add this import at the top of the test file - Dart doesn't expose a transitively-imported library's symbols unless re-exported, and `AccessoryBatteryStatus` is used directly in the new tests:

```dart
import 'package:macless_haystack/accessory/accessory_battery.dart';
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/accessory/accessory_model_test.dart`
Expected: FAIL - `lastNotifiedBatteryStatus` isn't defined on `Accessory`.

- [ ] **Step 3: Implement the field**

In `lib/accessory/accessory_model.dart`:

1. Add the field next to `lastBatteryStatus` (around line 75):

```dart
  /// The last known battery status
  /// (null if battery data not found)
  AccessoryBatteryStatus? lastBatteryStatus;

  /// The most severe [AccessoryBatteryStatus] we've already shown a
  /// low-battery notification for. Reset to null once the accessory's
  /// battery recovers above low, so a future drop alerts again.
  AccessoryBatteryStatus? lastNotifiedBatteryStatus;
```

2. In `clone()`, add `lastNotifiedBatteryStatus` to both the constructor call and as a post-construction assignment (the `Accessory` constructor doesn't take it as a named param - it's not part of the required "creation" shape, only a runtime-mutated tracking field, matching how `hasChangedFlag` is handled):

```dart
  Accessory clone() {
    var cloned = Accessory(
        datePublished: datePublished,
        id: id,
        name: name,
        hashedPublicKey: hashedPublicKey,
        color: color,
        icon: _icon,
        isActive: isActive,
        lastLocation: lastLocation,
        hashesWithTS: hashesWithTS,
        additionalKeys: additionalKeys,
        locationHistory: locationHistory,
        lastBatteryStatus: lastBatteryStatus);
    cloned.lastNotifiedBatteryStatus = lastNotifiedBatteryStatus;
    return cloned;
  }
```

3. In `Accessory.fromJson`, add after the existing `lastBatteryStatus` field initializer (still inside the initializer list, comma-separated):

```dart
        lastBatteryStatus = json['lastBatteryStatus'] != null
            ? AccessoryBatteryStatus.values.byName(json['lastBatteryStatus'])
            : null,
        lastNotifiedBatteryStatus = json['lastNotifiedBatteryStatus'] != null
            ? AccessoryBatteryStatus.values
                .byName(json['lastNotifiedBatteryStatus'])
            : null,
```

4. In `toJson()`, add alongside the existing `lastBatteryStatus` spread entry:

```dart
        ...lastBatteryStatus != null
            ? {'lastBatteryStatus': lastBatteryStatus!.name}
            : {},
        ...lastNotifiedBatteryStatus != null
            ? {'lastNotifiedBatteryStatus': lastNotifiedBatteryStatus!.name}
            : {}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/accessory/accessory_model_test.dart`
Expected: PASS (all existing tests plus the 4 new ones)

- [ ] **Step 5: Commit**

```bash
git add lib/accessory/accessory_model.dart test/accessory/accessory_model_test.dart
git commit -m "feat: track last-notified battery status on Accessory"
```

---

### Task 3: Notification service, navigation singleton, and platform setup

**Files:**
- Create: `lib/notifications/battery_notification_service.dart`
- Create: `lib/notifications/notification_navigation.dart`
- Test: `test/notifications/battery_notification_service_test.dart` (new)
- Modify: `pubspec.yaml` (dependency, via CLI - see Step 3)
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/res/drawable/ic_notification.xml`

**Interfaces:**
- Consumes: `Accessory` (from `lib/accessory/accessory_model.dart`), `AccessoryBatteryStatus` (from Task 1's file).
- Produces:
  - `class BatteryNotificationService { Future<void> init(); Future<void> notifyLowBattery(Accessory accessory); }` - instantiated and wired into `AccessoryRegistry` by Task 5, and instantiated once in `main.dart` by Task 5.
  - `String batteryNotificationTitle(String accessoryName, AccessoryBatteryStatus status)` and `String batteryNotificationBody(AccessoryBatteryStatus status)` - pure functions, exported from `battery_notification_service.dart`, used internally by `notifyLowBattery` and directly by this task's own tests (the plugin call itself isn't unit-testable, but the copy it's given is).
  - `class NotificationNavigation { static final ValueNotifier<String?> pendingAccessoryId = ValueNotifier<String?>(null); }` - consumed by Task 6.

- [ ] **Step 1: Write the failing tests**

Create `test/notifications/battery_notification_service_test.dart` - this covers only the pure copy-building functions; the actual plugin call requires a real platform channel and is verified manually (see the plan's final note):

```dart
import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:macless_haystack/notifications/battery_notification_service.dart';
import 'package:test/test.dart';

void main() {
  group('batteryNotificationTitle', () {
    test('low battery title names the accessory', () {
      expect(
        batteryNotificationTitle('Keys', AccessoryBatteryStatus.low),
        'Keys battery is low',
      );
    });

    test('criticalLow battery title names the accessory', () {
      expect(
        batteryNotificationTitle('Keys', AccessoryBatteryStatus.criticalLow),
        'Keys battery is critically low',
      );
    });
  });

  group('batteryNotificationBody', () {
    test('low battery body suggests recharging soon', () {
      expect(
        batteryNotificationBody(AccessoryBatteryStatus.low),
        'Consider replacing or recharging its battery soon.',
      );
    });

    test('criticalLow battery body warns reporting may stop', () {
      expect(
        batteryNotificationBody(AccessoryBatteryStatus.criticalLow),
        'It may stop reporting its location soon.',
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/notifications/battery_notification_service_test.dart`
Expected: FAIL - the `macless_haystack/notifications/battery_notification_service.dart` file doesn't exist yet.

- [ ] **Step 3: Add the dependency and platform setup**

Add the package (this resolves and pins a version compatible with this project's SDK constraints - do not hand-edit a version string into `pubspec.yaml`):

```bash
flutter pub add flutter_local_notifications
```

Add the runtime notification permission to `android/app/src/main/AndroidManifest.xml`, alongside the existing `<uses-permission>` lines near the top:

```xml
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

Create `android/app/src/main/res/drawable/ic_notification.xml` - a simple monochrome vector drawable (Android notification icons must be a white silhouette on transparent, not the full-color app icon; a filled circle-with-pin shape is a reasonable stand-in matching the app's existing `push_pin` motif used as `defaultIcon` in `lib/accessory/accessory_model.dart`):

```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24"
    android:tint="#FFFFFF">
    <path
        android:fillColor="#FF000000"
        android:pathData="M16,12V4h1V2H7v2h1v8l-2,2v2h5.2v6h1.6v-6H18v-2l-2,-2z"/>
</vector>
```

- [ ] **Step 4: Implement the service and navigation singleton**

Create `lib/notifications/notification_navigation.dart`:

```dart
import 'package:flutter/foundation.dart';

/// Connects "a low-battery notification was tapped" to "the UI should jump
/// to that accessory." A notification service has no reason to know about
/// tab indices or map controllers, and the dashboard/map widgets have no
/// reason to know about notification payloads - this is the one shared
/// piece of state between them.
class NotificationNavigation {
  NotificationNavigation._();

  /// The id of the accessory to jump to, or null when there's nothing
  /// pending. Set by [BatteryNotificationService]'s tap handler; cleared by
  /// whichever widget consumes it (see AccessoryMapListVertical).
  static final ValueNotifier<String?> pendingAccessoryId =
      ValueNotifier<String?>(null);
}
```

Create `lib/notifications/battery_notification_service.dart`:

```dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart';
import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/notifications/notification_navigation.dart';

const _channelId = 'low_battery';
const _channelName = 'Low battery';
const _channelDescription =
    'Alerts when a tracked accessory\'s battery is low or critically low.';

/// The notification title for [status] on an accessory named [accessoryName].
///
/// Only meaningful for [AccessoryBatteryStatus.low] and
/// [AccessoryBatteryStatus.criticalLow] - callers only invoke this after
/// already checking [isLowOrWorse].
String batteryNotificationTitle(
  String accessoryName,
  AccessoryBatteryStatus status,
) {
  return status == AccessoryBatteryStatus.criticalLow
      ? '$accessoryName battery is critically low'
      : '$accessoryName battery is low';
}

/// The notification body for [status]. See [batteryNotificationTitle].
String batteryNotificationBody(AccessoryBatteryStatus status) {
  return status == AccessoryBatteryStatus.criticalLow
      ? 'It may stop reporting its location soon.'
      : 'Consider replacing or recharging its battery soon.';
}

/// Shows an Android system notification when a tracked accessory's battery
/// drops to low or critically low. See
/// docs/superpowers/specs/2026-09-15-low-battery-notifications-design.md.
class BatteryNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  var logger = Logger(printer: PrettyPrinter(methodCount: 0));
  bool _initialized = false;

  /// Creates the Android notification channel and requests the
  /// POST_NOTIFICATIONS runtime permission (Android 13+; a no-op on older
  /// versions). Safe to call more than once - later calls are ignored.
  Future<void> init() async {
    if (_initialized) return;
    try {
      const androidSettings = AndroidInitializationSettings(
        '@drawable/ic_notification',
      );
      await _plugin.initialize(
        const InitializationSettings(android: androidSettings),
        onDidReceiveNotificationResponse: (response) {
          final accessoryId = response.payload;
          if (accessoryId != null) {
            NotificationNavigation.pendingAccessoryId.value = accessoryId;
          }
        },
      );

      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();

      _initialized = true;
    } catch (e) {
      logger.e('Failed to initialize battery notification service: $e');
    }
  }

  /// Shows a low-battery notification for [accessory]. [accessory.lastBatteryStatus]
  /// must already be [AccessoryBatteryStatus.low] or
  /// [AccessoryBatteryStatus.criticalLow] - callers are expected to have
  /// checked this via [isLowOrWorse] before calling.
  Future<void> notifyLowBattery(Accessory accessory) async {
    final status = accessory.lastBatteryStatus;
    if (status == null || !isLowOrWorse(status)) return;

    try {
      const androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      await _plugin.show(
        accessory.id.hashCode,
        batteryNotificationTitle(accessory.name, status),
        batteryNotificationBody(status),
        const NotificationDetails(android: androidDetails),
        payload: accessory.id,
      );
    } catch (e) {
      logger.e('Failed to show low-battery notification: $e');
    }
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/notifications/battery_notification_service_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 6: Run the full test suite to check nothing else broke**

Run: `flutter test`
Expected: PASS (adding a new dependency and two new files shouldn't affect any existing test)

- [ ] **Step 7: Commit**

```bash
git add pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml \
  android/app/src/main/res/drawable/ic_notification.xml \
  lib/notifications/battery_notification_service.dart \
  lib/notifications/notification_navigation.dart \
  test/notifications/battery_notification_service_test.dart
git commit -m "feat: add battery notification service and navigation singleton"
```

---

### Task 4: Settings toggle

**Files:**
- Modify: `lib/preferences/user_preferences_model.dart`
- Modify: `lib/preferences/preferences_page.dart`

**Interfaces:**
- Produces: `const String lowBatteryNotificationsEnabledKey = 'LOW_BATTERY_NOTIFICATIONS_ENABLED';` in `lib/preferences/user_preferences_model.dart`, read by Task 5 via `Settings.getValue<bool>(lowBatteryNotificationsEnabledKey, defaultValue: true)`.

This task has no dedicated automated test: it's a declarative settings-screen entry using the exact same `SwitchSettingsTile` machinery as every other toggle on this screen, none of which have their own widget tests in this codebase (confirmed: no test file covers `preferences_page.dart`'s existing tiles). Task 5's tests cover the *behavior* the key controls.

- [ ] **Step 1: Add the settings key**

In `lib/preferences/user_preferences_model.dart`, add alongside the other key constants:

```dart
const String lowBatteryNotificationsEnabledKey =
    'LOW_BATTERY_NOTIFICATIONS_ENABLED';
```

- [ ] **Step 2: Add the settings tile**

In `lib/preferences/preferences_page.dart`, add a new tile-getter method near `getFetchOnStartupTile()`:

```dart
  Widget getLowBatteryNotificationsTile() {
    return SwitchSettingsTile(
      settingKey: lowBatteryNotificationsEnabledKey,
      defaultValue: true,
      title: 'Low battery notifications',
      subtitle: 'Notify when a tracked accessory\'s battery is low',
    );
  }
```

Wire it into the settings screen's `build()` method as its own section, after the existing `'Location & fetching'` group:

```dart
          _sectionHeader(context, 'Location & fetching'),
          getLocationTile(),
          getFetchOnStartupTile(),
          getCompactAccessoryListTile(),
          getNumberofDaysTile(),
          _sectionHeader(context, 'Notifications'),
          getLowBatteryNotificationsTile(),
          _sectionHeader(context, 'General'),
```

- [ ] **Step 3: Run the full test suite to check nothing broke**

Run: `flutter test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/preferences/user_preferences_model.dart lib/preferences/preferences_page.dart
git commit -m "feat: add low-battery notifications settings toggle"
```

---

### Task 5: Wire notification triggering into AccessoryRegistry

**Files:**
- Modify: `lib/accessory/accessory_registry.dart`
- Modify: `lib/main.dart`
- Test: `test/accessory/accessory_registry_test.dart`
- Test: `test/accessory/accessory_registry_test.mocks.dart` (regenerated, not hand-edited - see Step 1)

**Interfaces:**
- Consumes: `isLowOrWorse`/`isMoreSevere` (Task 1), `Accessory.lastNotifiedBatteryStatus` (Task 2), `BatteryNotificationService` (Task 3), `lowBatteryNotificationsEnabledKey` (Task 4).
- Produces: `AccessoryRegistry.setBatteryNotificationService` (setter, test-only DI seam matching the existing `setStorage` pattern), used only by this task's own tests.

- [ ] **Step 1: Write the failing tests**

`test/accessory/accessory_registry_test.dart` already uses `@GenerateMocks([LocationModel, FlutterSecureStorage])` with `build_runner` generating `accessory_registry_test.mocks.dart`. Add `BatteryNotificationService` to that annotation:

```dart
@GenerateMocks([LocationModel, FlutterSecureStorage, BatteryNotificationService])
```

Add the import at the top of the file:

```dart
import 'package:macless_haystack/notifications/battery_notification_service.dart';
```

Regenerate the mocks file:

```bash
dart run build_runner build --delete-conflicting-outputs
```

In the `setUp(() { ... })` block, wire the mock in (matching the existing `registry.setStorage = MockFlutterSecureStorage();` line):

```dart
    registry.setBatteryNotificationService = MockBatteryNotificationService();
```

Add a new test group covering the full decision sequence from the spec (this exercises `_maybeNotifyBatteryChange` indirectly, through the real update path `fillLocationHistory` - the simpler of the two call sites to drive directly with a crafted report list, matching how the existing tests in this file already build `FindMyLocationReport.withHash(...)` fixtures):

```dart
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
```

(These new tests sit alongside the existing tests in `test/accessory/accessory_registry_test.dart`, inside the same top-level `main()`, using the same shared `registry`/`locationModel` fixtures already set up at the top of the file.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/accessory/accessory_registry_test.dart`
Expected: FAIL - `setBatteryNotificationService`, `setLowBatteryNotificationsEnabledCheck`, and `MockBatteryNotificationService` don't exist yet (the mock file was regenerated in Step 1, but the registry itself has no such setter yet).

- [ ] **Step 3: Implement the wiring**

In `lib/accessory/accessory_registry.dart`, add these two new imports (`user_preferences_model.dart` is already imported at line 13 for the existing `endpointUrl` key - do not add it again):

```dart
import 'package:macless_haystack/accessory/accessory_battery.dart';
import 'package:macless_haystack/notifications/battery_notification_service.dart';
```

Add the two DI seams next to the existing `_storage`/`setStorage` pair:

```dart
  BatteryNotificationService _batteryNotificationService =
      BatteryNotificationService();
  bool Function() _isLowBatteryNotificationsEnabled = () =>
      Settings.getValue<bool>(lowBatteryNotificationsEnabledKey,
          defaultValue: true) ??
      true;

  /// Test-only seam: overrides the real notification service with a fake.
  set setBatteryNotificationService(BatteryNotificationService service) {
    _batteryNotificationService = service;
  }

  /// Test-only seam: overrides the real settings-backed enabled check.
  set setLowBatteryNotificationsEnabledCheck(bool Function() check) {
    _isLowBatteryNotificationsEnabled = check;
  }
```

Add the decision method anywhere in the class body (near `fillLocationHistory`, which is its main caller):

```dart
  /// Notifies about [accessory]'s current [Accessory.lastBatteryStatus] if
  /// it just became low-or-worse for the first time, or escalated to a
  /// more severe low state, since the last time we notified. Resets the
  /// "already notified" marker once the battery recovers, so a later drop
  /// notifies again. See
  /// docs/superpowers/specs/2026-09-15-low-battery-notifications-design.md.
  Future<void> _maybeNotifyBatteryChange(Accessory accessory) async {
    if (!_isLowBatteryNotificationsEnabled()) return;

    var status = accessory.lastBatteryStatus;
    if (!isLowOrWorse(status)) {
      accessory.lastNotifiedBatteryStatus = null;
      return;
    }

    if (isMoreSevere(accessory.lastNotifiedBatteryStatus, status!)) {
      await _batteryNotificationService.notifyLowBattery(accessory);
      accessory.lastNotifiedBatteryStatus = status;
    }
  }
```

Call it at both existing `accessory.lastBatteryStatus = lastReport.batteryStatus;` sites:

In `loadLocationReports` (around the line commented `// Update last battery status`):

```dart
          // Update last battery status
          accessory.lastBatteryStatus = lastReport.batteryStatus;
          await _maybeNotifyBatteryChange(accessory);
          accessory.hasChangedFlag = true;
```

In `fillLocationHistory` (around the line commented `//Update alway battery status`):

```dart
        //Update alway battery status
        accessory.lastBatteryStatus = lastReport.batteryStatus;
        await _maybeNotifyBatteryChange(accessory);

        accessory.hasChangedFlag = true;
```

In `deleteData`, add the reset alongside the existing `accessory.lastBatteryStatus = null;`:

```dart
  void deleteData(Accessory accessory) {
    accessory.lastBatteryStatus = null;
    accessory.lastNotifiedBatteryStatus = null;
    accessory.lastLocation = null;
```

- [ ] **Step 4: Wire the real service into app startup**

In `lib/main.dart`, add the import:

```dart
import 'package:macless_haystack/notifications/battery_notification_service.dart';
```

In `main()`, after `await Settings.init();`, create and initialize one shared instance, then thread it into `MyApp`:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.init();
  var batteryNotificationService = BatteryNotificationService();
  await batteryNotificationService.init();
  await initializeDateFormatting();
  var initialThemeMode = themeModeFromString(
      Settings.getValue<String>(themeModeKey, defaultValue: themeModeSystemValue));
  var initialMapTileProvider = Settings.getValue<String>(mapTileProviderKey,
      defaultValue: mapTileProviderOsmValue)!;
  var initialCartoApiKey =
      Settings.getValue<String>(cartoApiKeyKey, defaultValue: '')!;
  runApp(MyApp(
    initialThemeMode: initialThemeMode,
    initialMapTileProvider: initialMapTileProvider,
    initialCartoApiKey: initialCartoApiKey,
    batteryNotificationService: batteryNotificationService,
  ));
}
```

Add the field/constructor param to `MyApp` and pass it into the `AccessoryRegistry` provider:

```dart
class MyApp extends StatelessWidget {
  final ThemeMode initialThemeMode;
  final String initialMapTileProvider;
  final String initialCartoApiKey;
  final BatteryNotificationService batteryNotificationService;

  const MyApp({
    super.key,
    required this.initialThemeMode,
    required this.initialMapTileProvider,
    required this.initialCartoApiKey,
    required this.batteryNotificationService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (ctx) {
          var registry = AccessoryRegistry();
          registry.setBatteryNotificationService = batteryNotificationService;
          return registry;
        }),
```

(Leave the rest of the provider list and `build()` method exactly as-is.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/accessory/accessory_registry_test.dart`
Expected: PASS (all existing tests plus the new low-battery-notification group and the `deleteData` reset test)

- [ ] **Step 6: Run the full test suite to check nothing else broke**

Run: `flutter test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/accessory/accessory_registry.dart lib/main.dart \
  test/accessory/accessory_registry_test.dart \
  test/accessory/accessory_registry_test.mocks.dart
git commit -m "feat: trigger low-battery notifications from the fetch flow"
```

---

### Task 6: Notification tap navigates to the accessory

**Files:**
- Modify: `lib/notifications/notification_navigation.dart`
- Modify: `lib/dashboard/dashboard.dart`
- Modify: `lib/dashboard/accessory_map_list_vert.dart`
- Test: `test/notifications/notification_navigation_test.dart` (new)

**Interfaces:**
- Consumes: `NotificationNavigation.pendingAccessoryId` (Task 3), `AccessoryRegistry.accessories` (existing getter).
- Produces: `LatLng? resolveNotifiedAccessoryLocation(String accessoryId, Iterable<Accessory> accessories)` in `lib/notifications/notification_navigation.dart`.

Rendering the real `AccessoryMapListVertical` in a widget test would pull in the real `AccessoryMap`, which needs a `MapTileProviderModel` provider and renders a live `TileLayer` that fetches map tiles over the network - exactly the "Provider/plugin scaffolding well beyond what this specific hazard needs" that `test/map/map_cluster_widget_test.dart` already avoids for the same reason. So instead of a widget test, the accessory-lookup logic is extracted into a plain, directly testable function, and the actual on-device navigation (does the map really recenter, does the tab really switch) is verified manually - it already was, per the spec's own Testing section ("tap-to-open navigation need[s] manual verification on the physical test device").

- [ ] **Step 1: Write the failing test**

Create `test/notifications/notification_navigation_test.dart`:

```dart
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/notifications/notification_navigation.dart';
import 'package:test/test.dart';

void main() {
  Accessory buildAccessory(String id, LatLng? location) {
    var accessory = Accessory(
        id: id,
        name: 'Test $id',
        hashedPublicKey: '',
        datePublished: null,
        hashesWithTS: {},
        locationHistory: [],
        lastBatteryStatus: null,
        additionalKeys: List.empty());
    accessory.lastLocation = location;
    return accessory;
  }

  test('resolves the location of a matching accessory', () {
    var target = buildAccessory('target', const LatLng(51.5, -0.1));
    var other = buildAccessory('other', const LatLng(1, 1));

    var result =
        resolveNotifiedAccessoryLocation('target', [other, target]);

    expect(result, const LatLng(51.5, -0.1));
  });

  test('returns null when no accessory matches the id', () {
    var other = buildAccessory('other', const LatLng(1, 1));

    var result = resolveNotifiedAccessoryLocation('missing', [other]);

    expect(result, isNull);
  });

  test('returns null when the matching accessory has no known location', () {
    var target = buildAccessory('target', null);

    var result = resolveNotifiedAccessoryLocation('target', [target]);

    expect(result, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/notifications/notification_navigation_test.dart`
Expected: FAIL - `resolveNotifiedAccessoryLocation` isn't defined.

- [ ] **Step 3: Implement the resolver**

In `lib/notifications/notification_navigation.dart`, add the import and function (keep the existing `NotificationNavigation` class exactly as it is from Task 3):

```dart
import 'package:latlong2/latlong.dart';
import 'package:macless_haystack/accessory/accessory_model.dart';

/// The location to center the map on for the accessory a tapped low-battery
/// notification referred to, or null if it no longer exists in [accessories]
/// or has no known location yet.
LatLng? resolveNotifiedAccessoryLocation(
  String accessoryId,
  Iterable<Accessory> accessories,
) {
  for (var accessory in accessories) {
    if (accessory.id == accessoryId) {
      return accessory.lastLocation;
    }
  }
  return null;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/notifications/notification_navigation_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Wire the map-side listener**

In `lib/dashboard/accessory_map_list_vert.dart`, add the import:

```dart
import 'package:macless_haystack/notifications/notification_navigation.dart';
```

In `_AccessoryMapListVerticalState`, register a listener in `initState` and remove it in `dispose`:

```dart
  @override
  void initState() {
    super.initState();
    _mapEventSubscription = _mapController.mapEventStream.listen((event) {
      if (event.source == MapEventSource.dragStart ||
          event.source == MapEventSource.multiFingerGestureStart) {
        _collapseSheetToPeek(above: _peekSize);
      }
    });
    NotificationNavigation.pendingAccessoryId
        .addListener(_handlePendingNotificationAccessory);
  }

  /// Centers the map on the accessory a low-battery notification was
  /// tapped for, then clears the pending id - deferred to a post-frame
  /// callback since this can fire mid-build (the listener is registered in
  /// initState, and ValueNotifier calls listeners synchronously).
  void _handlePendingNotificationAccessory() {
    var accessoryId = NotificationNavigation.pendingAccessoryId.value;
    if (accessoryId == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      var registry = Provider.of<AccessoryRegistry>(context, listen: false);
      var location =
          resolveNotifiedAccessoryLocation(accessoryId, registry.accessories);
      if (location != null) {
        _centerPoint(location);
      }
      NotificationNavigation.pendingAccessoryId.value = null;
    });
  }
```

Remove the listener in `dispose`:

```dart
  @override
  void dispose() {
    _mapEventSubscription?.cancel();
    NotificationNavigation.pendingAccessoryId
        .removeListener(_handlePendingNotificationAccessory);
    _sheetController.dispose();
    super.dispose();
  }
```

- [ ] **Step 6: Wire the dashboard-side tab switch**

In `lib/dashboard/dashboard.dart`, add the import:

```dart
import 'package:macless_haystack/notifications/notification_navigation.dart';
```

`_DashboardState` has no `dispose()` override today (confirmed: `grep -n "void dispose" lib/dashboard/dashboard.dart` finds nothing) - this task adds one. Add the listener registration at the end of the existing `initState()` body:

```dart
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
    // Load new location reports on app start. Silent even when it finds
    // new data - this is plumbing the app does on its own, not something
    // the user asked for by tapping refresh.
    if (Settings.getValue<bool>(
      fetchLocationOnStartupKey,
      defaultValue: true,
    )!) {
      loadLocationUpdates(null, showFeedback: false);
    }
    NotificationNavigation.pendingAccessoryId
        .addListener(_switchToMapTabForPendingNotification);
  }

  @override
  void dispose() {
    NotificationNavigation.pendingAccessoryId
        .removeListener(_switchToMapTabForPendingNotification);
    super.dispose();
  }

  /// Switches to the Map tab when a low-battery notification is tapped -
  /// AccessoryMapListVertical (already mounted at all times via the
  /// IndexedStack below) independently centers the map on the accessory
  /// itself; this only needs to make that tab visible.
  void _switchToMapTabForPendingNotification() {
    if (NotificationNavigation.pendingAccessoryId.value != null) {
      setState(() {
        _selectedIndex = 0;
      });
    }
  }
```

- [ ] **Step 7: Run the full test suite to check nothing broke**

Run: `flutter test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add lib/notifications/notification_navigation.dart lib/dashboard/dashboard.dart \
  lib/dashboard/accessory_map_list_vert.dart \
  test/notifications/notification_navigation_test.dart
git commit -m "feat: navigate to the accessory when its low-battery notification is tapped"
```

---

## Manual verification (user follow-up, not automated here)

This session has no network access to the user's physical Android device, so the following must be checked by the user after pulling and rebuilding, the same as prior features this session:

1. Install the rebuilt APK; confirm the Android 13+ "allow notifications" system prompt appears on first launch (or on first low-battery event, depending on where `init()`'s permission request actually surfaces on the real OS - this can vary by manufacturer skin).
2. Force an accessory's battery status to `low`/`criticalLow` (or wait for a real one) and confirm a system notification appears with the exact copy from the spec.
3. Confirm a second fetch with the same low status does not re-notify, and that escalating to `criticalLow` does.
4. Tap the notification and confirm the app opens to the Map tab, centered on that accessory.
5. Toggle "Low battery notifications" off in Settings and confirm no notification appears on a subsequent low-battery fetch.
