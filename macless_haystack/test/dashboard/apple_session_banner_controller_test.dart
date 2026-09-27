import 'package:macless_haystack/dashboard/apple_session_banner_controller.dart';
import 'package:test/test.dart';

void main() {
  test('starts neither expired nor visible', () {
    var controller = AppleSessionBannerController();

    expect(controller.expired, false);
    expect(controller.visible, false);
  });

  test('reportStale(true) marks expired and shows the banner', () {
    var controller = AppleSessionBannerController();

    controller.reportStale(true);

    expect(controller.expired, true);
    expect(controller.visible, true);
  });

  test('reportStale(false) clears both - a successful login or a non-stale fetch', () {
    var controller = AppleSessionBannerController()..reportStale(true);

    controller.reportStale(false);

    expect(controller.expired, false);
    expect(controller.visible, false);
  });

  test('dismiss hides the banner without forgetting the session is expired', () {
    var controller = AppleSessionBannerController()..reportStale(true);

    controller.dismiss();

    expect(controller.visible, false);
    expect(controller.expired, true);
  });

  test('a later reportStale(true) shows the banner again after a dismiss - '
      'it must not no-op just because expired did not change', () {
    var controller = AppleSessionBannerController()
      ..reportStale(true)
      ..dismiss();

    controller.reportStale(true);

    expect(controller.visible, true);
  });

  test('reportStale(null) - no opinion - leaves expired and visible untouched', () {
    var controller = AppleSessionBannerController()..reportStale(true);

    controller.reportStale(null);

    expect(controller.expired, true);
    expect(controller.visible, true);
  });

  test('a fetch with no opinion (null) does not hide a status-check-driven banner', () {
    // The status check found the session expired; a later fetch response
    // from an older server (or with no active accessories) has nothing to
    // say about it and must not clear the banner just by reporting null.
    var controller = AppleSessionBannerController()..reportStale(true);

    controller.reportStale(null);

    expect(controller.visible, true);
  });

  test('cancelled re-login: dismiss then a silently-ignored status check leaves it hidden', () {
    var controller = AppleSessionBannerController()..reportStale(true);

    controller.dismiss();
    // The re-login page was cancelled and the follow-up status check
    // failed/was skipped, so nothing reports a new opinion at all.
    controller.reportStale(null);

    expect(controller.visible, false);
    expect(controller.expired, true);
  });

  test('dismiss on an already-hidden banner does not notify', () {
    var controller = AppleSessionBannerController();
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.dismiss();

    expect(notifications, 0);
  });

  test('reportStale notifies listeners', () {
    var controller = AppleSessionBannerController();
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.reportStale(true);
    controller.reportStale(false);

    expect(notifications, 2);
  });
}
