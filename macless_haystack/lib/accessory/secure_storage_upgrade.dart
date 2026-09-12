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
  final entries = count == 1 ? 'item' : 'items';
  return 'Secure storage could not read $count stored $entries after this '
      'update. Any accessory whose private key was affected can no longer '
      'be decrypted on this device - re-import it from a backup if you have '
      'one.';
}
