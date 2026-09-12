/// Validates a poll-interval-hours input against the server's accepted
/// range (endpoint/mh_endpoint.py's _handle_post_history_devices), so a
/// bad value is caught locally instead of round-tripping to a 400.
///
/// The server itself accepts fractional hours, but the field only ever
/// displays whole hours, so a fractional input is rejected here rather
/// than silently rounded - matching validateRetentionDays instead of
/// discarding part of what the user typed with no visible feedback.
String? validatePollIntervalHours(String? input) {
  var value = int.tryParse(input ?? '');
  if (value == null || value < 1 || value > 720) {
    return 'Enter a whole number between 1 and 720 hours';
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

/// Same range check as [validatePollIntervalHours], but an empty input is
/// valid - used where leaving the field blank means "don't change this".
String? validateOptionalPollIntervalHours(String? input) {
  if (input == null || input.trim().isEmpty) {
    return null;
  }
  return validatePollIntervalHours(input);
}

/// Same range check as [validateRetentionDays], but an empty input is
/// valid - used where leaving the field blank means "don't change this".
String? validateOptionalRetentionDays(String? input) {
  if (input == null || input.trim().isEmpty) {
    return null;
  }
  return validateRetentionDays(input);
}
