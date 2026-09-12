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

  test('warns and names the entry count for discarded legacy data', () {
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.legacyDataDiscarded,
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

  test('does not claim decryption is impossible when data is still on disk',
      () {
    // legacyDataUnreadable with willDiscardOnNextAccess == false means the
    // ciphertext has not been touched: downgrading can still recover it.
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.legacyDataUnreadable,
      reason: SecureStorageUpgradeReason.removedCipher,
      entryCount: 3,
      willDiscardOnNextAccess: false,
    );

    final warning = secureStorageUpgradeWarning(status);

    expect(warning, isNotNull);
    expect(warning, isNot(contains('can no longer be decrypted')));
  });

  test('warns that data is unrecoverable once it will be discarded', () {
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.legacyDataUnreadable,
      reason: SecureStorageUpgradeReason.removedCipher,
      entryCount: 2,
      willDiscardOnNextAccess: true,
    );

    expect(
      secureStorageUpgradeWarning(status),
      contains('can no longer be decrypted'),
    );
  });

  test('does not print a literal zero when the platform omits entryCount',
      () {
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.legacyDataDiscarded,
      reason: SecureStorageUpgradeReason.missingKeyMaterial,
    );

    expect(secureStorageUpgradeWarning(status), isNot(contains('0 stored')));
  });

  test('does not warn when the check itself was inconclusive', () {
    const status = SecureStorageUpgradeStatus(
      state: SecureStorageUpgradeState.unknown,
      reason: SecureStorageUpgradeReason.authenticationRequired,
    );

    expect(secureStorageUpgradeWarning(status), isNull);
  });
}
