import 'package:intl/date_symbol_data_local.dart';
import 'package:macless_haystack/util/time_format.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en_US');
    await initializeDateFormatting('de_DE');
  });

  group('timeFormatPreferenceFromString', () {
    test('maps "12h" to h12', () {
      expect(timeFormatPreferenceFromString('12h'), TimeFormatPreference.h12);
    });

    test('maps "24h" to h24', () {
      expect(timeFormatPreferenceFromString('24h'), TimeFormatPreference.h24);
    });

    test('maps "system" to system', () {
      expect(
        timeFormatPreferenceFromString('system'),
        TimeFormatPreference.system,
      );
    });

    test('maps null to system', () {
      expect(timeFormatPreferenceFromString(null), TimeFormatPreference.system);
    });

    test('maps an unknown value to system', () {
      expect(
        timeFormatPreferenceFromString('garbage'),
        TimeFormatPreference.system,
      );
    });
  });

  group('formatTimeOfDay', () {
    final time = DateTime(2026, 9, 12, 14, 5);

    test('h12 renders a 12-hour clock with am/pm regardless of locale', () {
      var result = formatTimeOfDay(time, TimeFormatPreference.h12, 'de_DE');
      expect(result, '2:05 PM');
    });

    test('h24 renders a 24-hour clock regardless of locale', () {
      var result = formatTimeOfDay(time, TimeFormatPreference.h24, 'en_US');
      expect(result, '14:05');
    });

    test('system follows the given locale (en_US -> 12-hour)', () {
      var result = formatTimeOfDay(time, TimeFormatPreference.system, 'en_US');
      // en_US's CLDR data separates the am/pm marker with a narrow
      // no-break space (U+202F), not a regular space.
      expect(result, '2:05 PM');
    });

    test('system follows the given locale (de_DE -> 24-hour)', () {
      var result = formatTimeOfDay(time, TimeFormatPreference.system, 'de_DE');
      expect(result, '14:05');
    });

    test('h12 renders midnight and noon without an off-by-one', () {
      expect(
        formatTimeOfDay(
          DateTime(2026, 9, 12, 0, 5),
          TimeFormatPreference.h12,
          'en_US',
        ),
        '12:05 AM',
      );
      expect(
        formatTimeOfDay(
          DateTime(2026, 9, 12, 12, 5),
          TimeFormatPreference.h12,
          'en_US',
        ),
        '12:05 PM',
      );
    });

    test('falls back to a fixed 24-hour format for an unparseable locale', () {
      var result = formatTimeOfDay(time, TimeFormatPreference.h12, 'POSIX');
      expect(result, '14:05');
    });
  });

  group('formatRelativeTime', () {
    final now = DateTime(2026, 9, 13, 12, 0, 0);

    test('renders "just now" for anything under a minute old', () {
      expect(
        formatRelativeTime(now.subtract(const Duration(seconds: 30)), now),
        'just now',
      );
    });

    test('renders "just now" for a time slightly in the future', () {
      // Clock drift between device and server can make a very fresh report
      // appear to be a few seconds ahead of "now".
      expect(
        formatRelativeTime(now.add(const Duration(seconds: 5)), now),
        'just now',
      );
    });

    test('renders whole minutes under an hour old', () {
      expect(
        formatRelativeTime(now.subtract(const Duration(minutes: 5)), now),
        '5m ago',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(minutes: 59)), now),
        '59m ago',
      );
    });

    test('renders whole hours under a day old', () {
      expect(
        formatRelativeTime(now.subtract(const Duration(hours: 2)), now),
        '2h ago',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(hours: 23)), now),
        '23h ago',
      );
    });

    test('renders whole days under a week old', () {
      expect(
        formatRelativeTime(now.subtract(const Duration(days: 1)), now),
        '1d ago',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(days: 6)), now),
        '6d ago',
      );
    });

    test('falls back to a calendar date at a week or older', () {
      expect(
        formatRelativeTime(
          now.subtract(const Duration(days: 7)),
          now,
          locale: 'en_US',
        ),
        'Sep 6',
      );
    });
  });
}
