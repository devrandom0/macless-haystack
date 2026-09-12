import 'package:macless_haystack/history/archive_settings_validation.dart';
import 'package:test/test.dart';

void main() {
  group('validatePollIntervalHours', () {
    test('accepts the lower boundary (1)', () {
      expect(validatePollIntervalHours('1'), isNull);
    });

    test('accepts the upper boundary (720)', () {
      expect(validatePollIntervalHours('720'), isNull);
    });

    test('rejects just below the lower boundary (0)', () {
      expect(validatePollIntervalHours('0'), isNotNull);
    });

    test('rejects just above the upper boundary (721)', () {
      expect(validatePollIntervalHours('721'), isNotNull);
    });

    test('rejects a fractional value', () {
      expect(validatePollIntervalHours('4.5'), isNotNull);
    });

    test('rejects non-numeric input', () {
      expect(validatePollIntervalHours('abc'), isNotNull);
    });

    test('rejects empty input', () {
      expect(validatePollIntervalHours(''), isNotNull);
    });

    test('rejects null input', () {
      expect(validatePollIntervalHours(null), isNotNull);
    });
  });

  group('validateRetentionDays', () {
    test('accepts the lower boundary (1)', () {
      expect(validateRetentionDays('1'), isNull);
    });

    test('accepts the upper boundary (3650)', () {
      expect(validateRetentionDays('3650'), isNull);
    });

    test('rejects just below the lower boundary (0)', () {
      expect(validateRetentionDays('0'), isNotNull);
    });

    test('rejects just above the upper boundary (3651)', () {
      expect(validateRetentionDays('3651'), isNotNull);
    });

    test('rejects a fractional value', () {
      // int.tryParse returns null for non-integer strings, so "5.5" is
      // rejected the same way as any other unparseable input.
      expect(validateRetentionDays('5.5'), isNotNull);
    });

    test('rejects non-numeric input', () {
      expect(validateRetentionDays('abc'), isNotNull);
    });

    test('rejects empty input', () {
      expect(validateRetentionDays(''), isNotNull);
    });

    test('rejects null input', () {
      expect(validateRetentionDays(null), isNotNull);
    });
  });
}
