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
}
