import 'package:macless_haystack/dashboard/dashboard.dart';
import 'package:test/test.dart';

void main() {
  group('fetchFeedbackMessage', () {
    test(
      'returns null when feedback is suppressed, regardless of newCount',
      () {
        expect(
          fetchFeedbackMessage(
            showFeedback: false,
            newCount: 3,
            inactiveSkipped: 0,
          ),
          isNull,
        );
        expect(
          fetchFeedbackMessage(
            showFeedback: false,
            newCount: 0,
            inactiveSkipped: 0,
          ),
          isNull,
        );
      },
    );

    test('says there is no new data when newCount is zero', () {
      expect(
        fetchFeedbackMessage(
          showFeedback: true,
          newCount: 0,
          inactiveSkipped: 0,
        ),
        'No new locations.',
      );
    });

    test('reports the new count when there is new data', () {
      expect(
        fetchFeedbackMessage(
          showFeedback: true,
          newCount: 1,
          inactiveSkipped: 0,
        ),
        'Fetched 1 new location.',
      );
      expect(
        fetchFeedbackMessage(
          showFeedback: true,
          newCount: 3,
          inactiveSkipped: 0,
        ),
        'Fetched 3 new locations.',
      );
    });

    test('appends the inactive-skipped note when there is new data', () {
      expect(
        fetchFeedbackMessage(
          showFeedback: true,
          newCount: 2,
          inactiveSkipped: 1,
        ),
        'Fetched 2 new locations. 1 inactive accessory skipped',
      );
      expect(
        fetchFeedbackMessage(
          showFeedback: true,
          newCount: 2,
          inactiveSkipped: 2,
        ),
        'Fetched 2 new locations. 2 inactive accessories skipped',
      );
    });

    test('appends the inactive-skipped note when there is no new data too', () {
      expect(
        fetchFeedbackMessage(
          showFeedback: true,
          newCount: 0,
          inactiveSkipped: 1,
        ),
        'No new locations. 1 inactive accessory skipped',
      );
    });
  });
}
