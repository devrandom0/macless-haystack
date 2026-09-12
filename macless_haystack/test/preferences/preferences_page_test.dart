import 'package:macless_haystack/preferences/preferences_page.dart';
import 'package:test/test.dart';

void main() {
  group('passwordFieldTitle', () {
    test('shows the plain label when no password is stored', () {
      expect(passwordFieldTitle(''), 'Password for endpoint');
    });

    test('indicates a password is stored, without revealing it', () {
      const secret = 'correct horse battery staple';
      var title = passwordFieldTitle(secret);

      expect(title, 'Password for endpoint (set)');
      expect(title, isNot(contains(secret)));
    });
  });

  group('resolvePasswordEdit', () {
    test('returns the typed value when there was no existing password', () {
      expect(resolvePasswordEdit('new-pass', false), 'new-pass');
    });

    test('returns the typed value when it replaces an existing password',
        () {
      expect(resolvePasswordEdit('new-pass', true), 'new-pass');
    });

    test(
        'treats an empty submission as "keep the current password" when '
        'one is already set, not as clearing it', () {
      expect(resolvePasswordEdit('', true), isNull);
    });

    test('an empty submission with no existing password stays empty', () {
      expect(resolvePasswordEdit('', false), '');
    });

    test(
        'treats a whitespace-only submission the same as empty when a '
        'password already exists, so an accidental space bar press does '
        'not silently replace it', () {
      expect(resolvePasswordEdit('   ', true), isNull);
    });

    test('a literal whitespace password is still settable when none existed',
        () {
      expect(resolvePasswordEdit('   ', false), '   ');
    });
  });
}
