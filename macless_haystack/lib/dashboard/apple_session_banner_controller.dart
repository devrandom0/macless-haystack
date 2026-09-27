import 'package:flutter/foundation.dart';

/// Tracks whether the server's Apple session is known to be expired, and
/// separately whether the "log in again" banner should currently be
/// visible.
///
/// The two are kept apart deliberately: dismissing the banner (or
/// cancelling a re-login attempt) hides it without forgetting that the
/// session is still expired, so the next [reportStale] call that says so
/// shows it again - it must never no-op just because [expired] itself
/// didn't change.
class AppleSessionBannerController extends ChangeNotifier {
  bool _expired = false;
  bool _visible = false;

  bool get expired => _expired;
  bool get visible => _visible;

  /// Feeds in a new signal about the session's state - either a fetch's
  /// own flag, or an explicit status check. `null` means "no opinion"
  /// (an older server, or nothing left to check) and is ignored entirely;
  /// it must never clear a real signal.
  void reportStale(bool? stale) {
    if (stale == null) return;
    _expired = stale;
    _visible = stale;
    notifyListeners();
  }

  /// Hides the banner without forgetting the session is still expired.
  void dismiss() {
    if (!_visible) return;
    _visible = false;
    notifyListeners();
  }
}
