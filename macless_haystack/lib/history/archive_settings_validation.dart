/// Validates a poll-interval-hours input against the server's accepted
/// range (endpoint/mh_endpoint.py's _handle_post_history_devices), so a
/// bad value is caught locally instead of round-tripping to a 400.
String? validatePollIntervalHours(String? input) {
  var value = double.tryParse(input ?? '');
  if (value == null || !value.isFinite || value < 1 || value > 720) {
    return 'Enter a number between 1 and 720 hours';
  }
  return null;
}

/// Validates a retention-days input against the server's accepted range.
String? validateRetentionDays(String? input) {
  var value = int.tryParse(input ?? '');
  if (value == null || value < 1 || value > 3650) {
    return 'Enter a whole number between 1 and 3650 days';
  }
  return null;
}
