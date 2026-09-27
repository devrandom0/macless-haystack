import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Thrown when the server's live Apple fetch failed on an expired session
/// with no cached data to fall back on (its 503 `apple_session_expired`).
class AppleSessionExpiredException implements Exception {
  const AppleSessionExpiredException();

  @override
  String toString() => 'The Apple ID session has expired; log in again.';
}

/// The decoded reports from a fetch, plus the server's own count of how
/// many of them came from a live Apple fetch versus its cache. This is a
/// server-side signal only (falls back to the full report count if the
/// server doesn't send it) - it does not mean "new to this client", since
/// the app's own automatic fetches and the server's background archiver
/// both independently keep the server's cache warm. Callers that need
/// "have I already seen this" should compare against locally known data
/// instead (see AccessoryRegistry.countNewReports).
///
/// [appleSessionStale] mirrors the server's own `apple_session_stale` flag
/// (false when an older server doesn't send it at all): a 200 response can
/// still be built entirely from cache after a failed live Apple call, and
/// this is how that gets surfaced instead of failing silently.
typedef LocationReportsResult = ({
  List reports,
  int newCount,
  bool appleSessionStale,
});

class ReportsFetcher {
  /// Fetches the location reports corresponding to the given hashed advertisement
  /// key.
  /// Throws [Exception] if no answer was received. Throws
  /// [AppleSessionExpiredException] when the server reports no cache to
  /// fall back on for an expired Apple session.
  ///
  static var logger = Logger(printer: PrettyPrinter(methodCount: 0));

  // Without a deadline, a blackholed request hangs this Future forever -
  // and with it, RefreshAction's busy guard, permanently disabling the
  // refresh button until the app restarts.
  static const _requestTimeout = Duration(seconds: 30);

  static http.Client _createClient() {
    if (kIsWeb) {
      return http.Client();
    }
    var ioClient = HttpClient();
    /*Ignore certificate errors*/
    ioClient.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
    return IOClient(ioClient);
  }

  static Future<LocationReportsResult> fetchLocationReports(
    Iterable<String> hashedAdvertisementKeys,
    int daysToFetch,
    String url,
    String user,
    String pass, {
    bool force = false,
    http.Client? client,
  }) async {
    var keys = hashedAdvertisementKeys.toList(growable: false);
    logger.i('Using ${keys.length} key(s) to ask webservice');

    String? credentials;
    if (user.trim().isNotEmpty || pass.trim().isNotEmpty) {
      credentials = 'Basic ${base64.encode(utf8.encode("$user:$pass"))}';
    }

    var requestBody = jsonEncode(<String, dynamic>{
      "ids": keys,
      "days": daysToFetch,
      "force": force,
    });

    var headers = {
      "Content-Type": "application/json",
      if (credentials != null) "Authorization": credentials,
    };

    var effectiveClient = client ?? _createClient();
    try {
      var response = await effectiveClient
          .post(Uri.parse(url), headers: headers, body: requestBody)
          .timeout(_requestTimeout);

      if (response.statusCode == 401) {
        throw Exception(
          "Authentication failure. Username or password is incorrect.",
        );
      }
      if (response.statusCode == 503) {
        Map<String, dynamic>? decoded;
        try {
          decoded = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          decoded = null;
        }
        if (decoded?['error'] == 'apple_session_expired') {
          throw const AppleSessionExpiredException();
        }
      }
      if (response.statusCode == 200) {
        var decoded = jsonDecode(response.body);
        var out = decoded["results"] as List;
        var newCount = decoded["new_count"] is int
            ? decoded["new_count"] as int
            : out.length;
        var appleSessionStale = decoded["appleSessionStale"] == true;
        logger.i('Found ${out.length} reports, $newCount new');
        return (
          reports: out,
          newCount: newCount,
          appleSessionStale: appleSessionStale,
        );
      }
      throw Exception(
        "Failed to fetch location reports with status code ${response.statusCode}.\n\nResponse:\n$response",
      );
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }
}
