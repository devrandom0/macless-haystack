# Low-battery notifications

## Motivation

Every accessory already carries a battery status (`AccessoryBatteryStatus`: `ok`, `medium`, `low`, `criticalLow`, `unknown`), updated whenever the app fetches reports (startup, manual refresh, or force refresh). Today that status is only visible if the user opens the app and looks - there's no alert when a tracked item's battery drops low enough that it might stop reporting soon. Other tracker apps (Apple Find My, Samsung SmartThings Find, Tile) all alert on this; it's a natural addition here since the underlying data already exists.

Goal: notify the user (Android system notification) the first time a tracked accessory's battery drops to `low` or `criticalLow`, without spamming on every subsequent fetch while it stays there.

## Non-goals

- No background polling. The app has no periodic background task or foreground service today (confirmed: no `WorkManager`/`background_fetch` dependency, no lifecycle-triggered refresh). A notification can only fire as a side effect of a fetch that already happens (app startup, manual refresh, force refresh) while the app process is running. Adding true "notify while fully closed" support is a separate, much larger feature (background task scheduling, battery-usage tradeoffs) and is explicitly out of scope.
- Android only. The app also builds for Linux desktop and Web, but this feature ships for Android only - the only platform this app sees real-world usage on. Desktop/web notifications are a separate feature if ever wanted.
- No notification for `unknown` battery status. `unknown` means "no data," not "bad battery" - it must never be treated as more severe than `criticalLow` despite sitting later in the enum's declared order (see Architecture).
- No changes to how battery status itself is fetched/decrypted/displayed. This only adds an alert on top of the existing `lastBatteryStatus` field.

## Architecture

**Severity helper, not enum-index comparison.** `AccessoryBatteryStatus` is declared as `ok, medium, low, criticalLow, unknown` - `unknown` sits after `criticalLow` in that list but isn't more severe than it, so comparing by `Enum.index` is unsafe. `lib/accessory/accessory_battery.dart` gains two pure functions:

```dart
/// Whether [status] represents a battery level worth alerting on.
bool isLowOrWorse(AccessoryBatteryStatus? status) {
  return status == AccessoryBatteryStatus.low ||
      status == AccessoryBatteryStatus.criticalLow;
}

/// Whether [status] is strictly more severe than [previous].
/// Only meaningful when both are low-or-worse; [previous] may be null
/// (never notified yet).
bool isMoreSevere(
  AccessoryBatteryStatus? previous,
  AccessoryBatteryStatus status,
) {
  if (previous == null) return true;
  const order = {
    AccessoryBatteryStatus.low: 0,
    AccessoryBatteryStatus.criticalLow: 1,
  };
  return (order[status] ?? -1) > (order[previous] ?? -1);
}
```

**New field on `Accessory`** (`lib/accessory/accessory_model.dart`): `AccessoryBatteryStatus? lastNotifiedBatteryStatus`. Tracks the most severe status we've already alerted on for this accessory, so a fetch that keeps returning `low` doesn't re-notify, but an escalation from `low` to `criticalLow` does. Persisted via `toJson`/`fromJson` exactly like `lastBatteryStatus` (optional key, omitted when null), and included in `clone()`/`update()` alongside it.

**New file `lib/notifications/battery_notification_service.dart`**: wraps the `flutter_local_notifications` package.

- `Future<void> init()` - creates the Android notification channel (id `low_battery`, importance default) and requests the `POST_NOTIFICATIONS` runtime permission (Android 13+; no-op on older versions). The permission request is fired without being awaited, since on Android 13+ it blocks on the user's response to the system dialog - awaiting it here would block `main()`'s call to `init()`, which runs before `runApp()`, so the first frame would never render behind a bare launch theme until the user answers. `init()` also seeds `NotificationNavigation.pendingAccessoryId` by calling `getNotificationAppLaunchDetails()`: `onDidReceiveNotificationResponse` (the tap-response callback below) only fires while the app process is already alive, so a tap that launches the app from a fully killed state needs this separate path instead. Called once from `main.dart` during startup, alongside the app's other service initialization.
- `Future<void> notifyLowBattery(Accessory accessory)` - shows a notification with the accessory's `id` as payload:
  - `low`: title `'${accessory.name} battery is low'`, body `'Consider replacing or recharging its battery soon.'`
  - `criticalLow`: title `'${accessory.name} battery is critically low'`, body `'It may stop reporting its location soon.'`
- A tap-response callback (`onDidReceiveNotificationResponse`) that reads the payload and forwards it to the navigation hook below.

**New file `lib/notifications/notification_navigation.dart`**: a small singleton holding `static final ValueNotifier<String?> pendingAccessoryId = ValueNotifier<String?>(null)`. This is the one piece of shared state connecting "a notification was tapped" to "the UI should jump to that accessory" - the two are otherwise unrelated (a notification service class has no reason to know about tab indices or map controllers).

**Settings toggle** (`lib/preferences/preferences_page.dart`): a `SwitchSettingsTile` following the exact pattern already used there (e.g. the "Fetch locations on startup" tile) - key `lowBatteryNotificationsEnabled`, default `true`. Checked before ever calling `notifyLowBattery`.

## Dependencies & platform setup

- `pubspec.yaml` gains `flutter_local_notifications: ^19.4.2` (latest stable at time of writing; the implementer should verify against the pinned Flutter/Dart SDK constraint already in `pubspec.yaml` and adjust if a newer/older major is required for compatibility).
- `android/app/src/main/AndroidManifest.xml` gains `<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>` (required for the runtime prompt on API 33+; older Android versions grant it at install time and ignore the runtime request).
- A monochrome notification icon drawable is required by Android's notification system (a colored app icon is rejected/rendered as a white square). Reuse the existing app icon's shape as a solid-white silhouette, added under `android/app/src/main/res/drawable/ic_notification.xml` (a vector drawable is simplest - no per-density PNG exports needed).

## Data flow

1. A fetch completes (`loadLocationUpdates` in `dashboard.dart`, triggered by startup/manual/force refresh) and `AccessoryRegistry` updates `accessory.lastBatteryStatus` from the newest report, at its two existing update sites (`loadLocationReports` and `fillLocationHistory` in `accessory_registry.dart`).
2. Immediately after each of those two updates, a new private helper `_maybeNotifyBatteryChange(Accessory accessory)` runs:
   - If the setting `lowBatteryNotificationsEnabled` is off, do nothing.
   - If `accessory.lastBatteryStatus` is a known-good status (`ok`/`medium`), reset `accessory.lastNotifiedBatteryStatus = null` (clears the "already alerted" marker so a future drop alerts again) and return - this is a real recovery.
   - If `accessory.lastBatteryStatus` is `unknown`/`null` (no reliable reading), leave `accessory.lastNotifiedBatteryStatus` untouched and return - a missing/unreadable report is not a recovery, and resetting the marker here would silently re-arm and re-notify on the next low reading even though nothing about the battery actually improved.
   - Otherwise, if `isMoreSevere(accessory.lastNotifiedBatteryStatus, accessory.lastBatteryStatus!)`, call `BatteryNotificationService.notifyLowBattery(accessory)` and set `accessory.lastNotifiedBatteryStatus = accessory.lastBatteryStatus`.
   - Otherwise (already notified at this severity), do nothing.
3. `deleteData()` (accessory deactivation) also resets `lastNotifiedBatteryStatus = null`, alongside its existing `lastBatteryStatus = null` reset, so reactivating an accessory doesn't inherit a stale suppression state.
4. User taps the notification. `BatteryNotificationService`'s tap callback sets `NotificationNavigation.pendingAccessoryId.value = <accessory id>`.
5. `Dashboard` (already the owner of the bottom tab `IndexedStack`) listens to `NotificationNavigation.pendingAccessoryId` in `initState`; on a non-null value it switches the visible tab to the Map tab (index 0).
6. `AccessoryMapListVertical` (already mounted at all times via the `IndexedStack`, per its existing doc comment) independently listens to the same notifier in its `initState`; on a non-null value it resolves the `Accessory` via `AccessoryRegistry` and calls its existing `_centerPoint(accessory.lastLocation!)` - the same method already used when tapping a row in the accessory list - then clears `pendingAccessoryId` back to null via a post-frame callback, matching the existing addPostFrameCallback-deferred-state-change pattern already used elsewhere in this file for map-related selection changes. Clearing happens exactly once, from this single listener, to avoid a re-entrant notify loop.
7. If the accessory has no known location (`lastLocation == null` - e.g. never reported yet), step 6 skips centering and does nothing further; the user still lands on the Map tab from step 5.

## Error handling

- Notification permission denied by the user: `flutter_local_notifications`'s `show()` call silently does nothing (no exception, no display). No retry prompts, no blocking - the user made their choice at the OS permission dialog.
- Notification channel/service fails to initialize (e.g. unexpected platform exception during `init()`): caught and logged; the rest of the app's startup is unaffected. Low-battery notifications simply won't show for that session, everything else works normally.
- Tapped notification's accessory id no longer exists in the registry (accessory deleted since the notification fired): step 6 finds no matching accessory, does nothing beyond switching to the Map tab.

## Testing

- `isLowOrWorse` / `isMoreSevere`: pure functions, straightforward unit tests - `ok`/`medium`/`unknown`/`null` are not low-or-worse; `low` and `criticalLow` are; `isMoreSevere(null, low)` is true (first alert); `isMoreSevere(low, low)` is false (no re-alert); `isMoreSevere(low, criticalLow)` is true (escalation); `isMoreSevere(criticalLow, low)` is false (de-escalation isn't "more severe").
- `_maybeNotifyBatteryChange` decision logic: unit-testable against a fake/mock notification service - covers the full sequence "ok -> low fires once, stays low does not re-fire, low -> criticalLow fires again, criticalLow -> ok resets, ok -> criticalLow fires directly (skipping low)."
- `Accessory.toJson`/`fromJson` round-trip: extend the existing accessory serialization tests to cover `lastNotifiedBatteryStatus` (present when set, absent when null, matching the existing `lastBatteryStatus` pattern).
- Settings toggle: verify `lowBatteryNotificationsEnabled` defaults to `true` and gates the notification call when read back false, following the existing settings-tile test pattern if one exists for other switches in this file.
- Actual OS notification display, the Android 13+ permission prompt, and tap-to-open navigation need manual verification on the physical test device (adb), the same as prior features this session - `flutter_local_notifications`'s platform channel behavior isn't meaningfully testable in `flutter test`.

## Follow-ups (explicitly out of scope here)

- Background polling for a true "notified even while the app is fully closed" experience.
- Desktop (Linux) or Web notification support.
- A per-accessory mute/snooze control beyond the global settings toggle.
