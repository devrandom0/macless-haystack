import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Builds a user-facing warning for a [SecureStorageUpgradeStatus] report, or
/// null when there is nothing the user needs to know.
///
/// flutter_secure_storage v11 dropped the pre-v10 cipher/backends without a
/// migration path, so a user who skipped straight from v9 to this release can
/// have accessory private keys go silently unreadable - since the private key
/// IS the tag, that accessory becomes untrackable with no export to recover
/// from. [status.hasDataLoss] is exactly that case.
String? secureStorageUpgradeWarning(SecureStorageUpgradeStatus status) {
  if (!status.hasDataLoss) {
    return null;
  }
  final count = status.entryCount;
  // entryCount defaults to 0 in the platform interface, so a native side
  // that omits it should read as "unknown", not "zero".
  final countPhrase = count > 0
      ? '$count stored ${count == 1 ? 'item' : 'items'}'
      : 'some stored items';
  // legacyDataUnreadable with willDiscardOnNextAccess == false means the
  // ciphertext is untouched on disk; downgrading can still recover it. Every
  // other data-loss state (legacyDataDiscarded, or willDiscardOnNextAccess)
  // means the data is actually gone.
  final recoverable =
      status.state == SecureStorageUpgradeState.legacyDataUnreadable &&
          !status.willDiscardOnNextAccess;
  if (recoverable) {
    return 'Secure storage could not read $countPhrase after this update. '
        'That data has not been deleted yet - downgrading the app can still '
        'recover it, but avoid using this device to add or remove '
        'accessories until you decide.';
  }
  return 'Secure storage could not read $countPhrase after this update. '
      'Any accessory whose private key was affected can no longer '
      'be decrypted on this device - re-import it from a backup if you have '
      'one.';
}
