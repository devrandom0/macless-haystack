import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:macless_haystack/accessory/secure_storage_upgrade.dart';
import 'package:test/test.dart';

void main() {
  test('returns null when the storage reports no data loss', () {
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.ok,
    );

    expect(secureStorageUpgradeWarning(status), isNull);
  });

  test('warns and names the entry count for unreadable legacy data', () {
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.legacyDataUnreadable,
      reason: SecureStorageUpgradeReason.removedCipher,
      entryCount: 3,
    );

    final warning = secureStorageUpgradeWarning(status);

    expect(warning, isNotNull);
    expect(warning, contains('3'));
  });

  test('warns when unreadable legacy data was already discarded', () {
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.legacyDataDiscarded,
      reason: SecureStorageUpgradeReason.missingAlgorithmMarkers,
      entryCount: 1,
    );

    expect(secureStorageUpgradeWarning(status), isNotNull);
  });

  test('does not warn when the check itself was inconclusive', () {
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.unknown,
      reason: SecureStorageUpgradeReason.authenticationRequired,
    );

    expect(secureStorageUpgradeWarning(status), isNull);
  });
}
