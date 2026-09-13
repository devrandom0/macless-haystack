import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// The decoded reports from a fetch, plus the server's own count of how
/// many of them came from a live Apple fetch versus its cache. This is a
/// server-side signal only (falls back to the full report count if the
/// server doesn't send it) - it does not mean "new to this client", since
/// the app's own automatic fetches and the server's background archiver
/// both independently keep the server's cache warm. Callers that need
/// "have I already seen this" should compare against locally known data
/// instead (see AccessoryRegistry.countNewReports).
typedef LocationReportsResult = ({List reports, int newCount});

class ReportsFetcher {
  /// Fetches the location reports corresponding to the given hashed advertisement
  /// key.
  /// Throws [Exception] if no answer was received.
  ///
  static var logger = Logger(printer: PrettyPrinter(methodCount: 0));

  // Without a deadline, a blackholed request hangs this Future forever -
  // and with it, RefreshAction's busy guard, permanently disabling the
  // refresh button until the app restarts.
  static const _requestTimeout = Duration(seconds: 30);

  static Future<LocationReportsResult> fetchLocationReports(
    Iterable<String> hashedAdvertisementKeys,
    int daysToFetch,
    String url,
    String user,
    String pass, {
    bool force = false,
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

    if (kIsWeb) {
      Map<String, String> requestHeaders = {"Content-Type": "application/json"};
      if (credentials != null) {
        requestHeaders['Authorization'] = credentials;
      }

      final response = await http
          .post(Uri.parse(url), headers: requestHeaders, body: requestBody)
          .timeout(_requestTimeout);
      if (response.statusCode == 401) {
        throw Exception(
          "Authentication failure. Username or password is incorrect.",
        );
      }
      if (response.statusCode == 200) {
        var decoded = jsonDecode(response.body);
        var out = decoded["results"] as List;
        var newCount = decoded["new_count"] is int
            ? decoded["new_count"] as int
            : out.length;
        logger.i('Found ${out.length} reports, $newCount new');
        return (reports: out, newCount: newCount);
      } else {
        throw Exception(
          "Failed to fetch location reports with status code ${response.statusCode}.\n\nResponse:\n$response",
        );
      }
    } else {
      var httpClient = HttpClient();
      /*Ignore certificate errors*/
      httpClient.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;

      final request = await httpClient
          .postUrl(Uri.parse(url))
          .timeout(_requestTimeout);
      request.headers.set(HttpHeaders.contentTypeHeader, "application/json");
      if (credentials != null) {
        request.headers.set(HttpHeaders.authorizationHeader, credentials);
      }

      request.headers.set(
        HttpHeaders.contentLengthHeader,
        utf8.encode(requestBody).length,
      );
      request.write(requestBody);
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode == 401) {
        throw Exception(
          "Authentication failure. Username or password is incorrect.",
        );
      }
      if (response.statusCode == 200) {
        String responseBody = await response
            .transform(utf8.decoder)
            .join()
            .timeout(_requestTimeout);
        var decoded = jsonDecode(responseBody);
        var out = decoded["results"] as List;
        var newCount = decoded["new_count"] is int
            ? decoded["new_count"] as int
            : out.length;
        logger.i('Found ${out.length} reports, $newCount new');
        return (reports: out, newCount: newCount);
      } else {
        throw Exception(
          "Failed to fetch location reports with status code ${response.statusCode}.\n\nResponse:\n$response",
        );
      }
    }
  }
}
