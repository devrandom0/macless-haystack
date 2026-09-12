import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Thrown when a call requires an https:// endpoint URL but the configured
/// one isn't - no request is ever sent in that case.
class AppleAuthHttpsRequiredException implements Exception {
  const AppleAuthHttpsRequiredException();

  @override
  String toString() =>
      'In-app Apple ID login requires an https:// endpoint URL.';
}

/// Thrown when the server rejects a login/verify attempt, carrying the
/// server's own error code (e.g. "invalid_credentials", "invalid_code").
class AppleAuthException implements Exception {
  final String errorCode;
  final String? message;

  const AppleAuthException(this.errorCode, [this.message]);

  @override
  String toString() => message ?? errorCode;
}

enum AppleAuthMethod { sms, trustedDevice }

AppleAuthMethod _parseMethod(String method) {
  switch (method) {
    case 'sms':
      return AppleAuthMethod.sms;
    case 'trusted_device':
      return AppleAuthMethod.trustedDevice;
    default:
      throw AppleAuthException('unknown_method', 'Unrecognized 2FA method: $method');
  }
}

class AppleLoginResult {
  final bool authenticated;
  final AppleAuthMethod? codeRequiredMethod;

  const AppleLoginResult.authenticated()
      : authenticated = true,
        codeRequiredMethod = null;

  const AppleLoginResult.codeRequired(this.codeRequiredMethod) : authenticated = false;
}

class AppleAuthStatus {
  final bool loggedIn;
  final bool pending;

  const AppleAuthStatus({required this.loggedIn, required this.pending});

  static AppleAuthStatus fromJson(Map<String, dynamic> json) {
    return AppleAuthStatus(
      loggedIn: json['loggedIn'] == true,
      pending: json['pending'] == true,
    );
  }
}

/// Drives the server's Apple ID login flow (`/auth/apple/login`,
/// `/auth/apple/verify`, `/auth/apple/status`).
class AppleAuthService {
  static http.Client _createClient() {
    if (kIsWeb) {
      return http.Client();
    }
    var ioClient = HttpClient();
    ioClient.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    return IOClient(ioClient);
  }

  static String? _authHeader(String user, String pass) {
    if (user.trim().isNotEmpty || pass.trim().isNotEmpty) {
      return 'Basic ${base64.encode(utf8.encode("$user:$pass"))}';
    }
    return null;
  }

  static void _requireHttps(String url) {
    if (Uri.parse(url).scheme != 'https') {
      throw const AppleAuthHttpsRequiredException();
    }
  }

  static Future<Map<String, dynamic>> _post(
      String url, String path, String user, String pass, Map<String, dynamic> body,
      {http.Client? client}) async {
    var effectiveClient = client ?? _createClient();
    try {
      var authHeader = _authHeader(user, pass);
      var headers = {
        "Content-Type": "application/json",
        if (authHeader != null) "Authorization": authHeader,
      };
      var response =
          await effectiveClient.post(Uri.parse('$url$path'), headers: headers, body: jsonEncode(body));
      if (response.statusCode != 200) {
        String? errorCode;
        String? message;
        try {
          var decoded = jsonDecode(response.body) as Map<String, dynamic>;
          errorCode = decoded['error'] as String?;
          message = decoded['message'] as String?;
        } catch (_) {
          // Non-JSON error body (e.g. a proxy's own error page) - fall
          // back to a generic code instead of crashing on the parse.
        }
        throw AppleAuthException(errorCode ?? 'request_failed', message);
      }
      return response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }

  /// Starts an Apple ID login. Throws [AppleAuthHttpsRequiredException]
  /// without making any request if [url] isn't https. Throws
  /// [AppleAuthException] with the server's error code on failure.
  static Future<AppleLoginResult> login(
      String url, String endpointUser, String endpointPass, String appleUsername, String applePassword,
      {http.Client? client}) async {
    _requireHttps(url);
    var decoded = await _post(url, '/auth/apple/login', endpointUser, endpointPass, {
      'username': appleUsername,
      'password': applePassword,
    }, client: client);

    if (decoded['status'] == 'authenticated') {
      return const AppleLoginResult.authenticated();
    }
    return AppleLoginResult.codeRequired(_parseMethod(decoded['method']));
  }

  /// Submits a 2FA code for a login started with [login]. Same HTTPS and
  /// error-handling rules as [login].
  static Future<void> verifyCode(String url, String endpointUser, String endpointPass, String code,
      {http.Client? client}) async {
    _requireHttps(url);
    await _post(url, '/auth/apple/verify', endpointUser, endpointPass, {'code': code}, client: client);
  }

  /// Ends the server's current Apple session (deletes its saved session
  /// file) so the next login starts fresh. Does not enforce HTTPS - no
  /// credential is sent.
  static Future<void> logout(String url, String endpointUser, String endpointPass,
      {http.Client? client}) async {
    await _post(url, '/auth/apple/logout', endpointUser, endpointPass, {}, client: client);
  }

  /// Fetches whether the server currently has a valid Apple session, and
  /// whether a login is mid-flow. Does not enforce HTTPS - the response
  /// carries no credential.
  static Future<AppleAuthStatus> getStatus(String url, String endpointUser, String endpointPass,
      {http.Client? client}) async {
    var effectiveClient = client ?? _createClient();
    try {
      var authHeader = _authHeader(endpointUser, endpointPass);
      var headers = {if (authHeader != null) "Authorization": authHeader};
      var response = await effectiveClient.get(Uri.parse('$url/auth/apple/status'), headers: headers);
      if (response.statusCode != 200) {
        throw Exception('Apple auth status request failed with status code ${response.statusCode}');
      }
      return AppleAuthStatus.fromJson(jsonDecode(response.body));
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }
}
