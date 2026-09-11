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
          timeFormatPreferenceFromString('system'), TimeFormatPreference.system);
    });

    test('maps null to system', () {
      expect(timeFormatPreferenceFromString(null), TimeFormatPreference.system);
    });

    test('maps an unknown value to system', () {
      expect(
          timeFormatPreferenceFromString('garbage'), TimeFormatPreference.system);
    });
  });

  group('formatTimeOfDay', () {
    final time = DateTime(2026, 9, 12, 14, 5);

    test('h12 renders a 12-hour clock with am/pm regardless of locale', () {
      var result =
          formatTimeOfDay(time, TimeFormatPreference.h12, 'de_DE');
      expect(result, '2:05 PM');
    });

    test('h24 renders a 24-hour clock regardless of locale', () {
      var result =
          formatTimeOfDay(time, TimeFormatPreference.h24, 'en_US');
      expect(result, '14:05');
    });

    test('system follows the given locale (en_US -> 12-hour)', () {
      var result =
          formatTimeOfDay(time, TimeFormatPreference.system, 'en_US');
      // en_US's CLDR data separates the am/pm marker with a narrow
      // no-break space (U+202F), not a regular space.
      expect(result, '2:05 PM');
    });

    test('system follows the given locale (de_DE -> 24-hour)', () {
      var result =
          formatTimeOfDay(time, TimeFormatPreference.system, 'de_DE');
      expect(result, '14:05');
    });
  });
}
