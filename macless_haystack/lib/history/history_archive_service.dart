import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class HistoryDeviceEntry {
  final String hashedPublicKey;
  final String privateKey;
  final String name;
  final String? accessoryId;
  final bool enabled;

  const HistoryDeviceEntry({
    required this.hashedPublicKey,
    required this.privateKey,
    required this.name,
    required this.accessoryId,
    required this.enabled,
  });

  Map<String, dynamic> toJson() => {
        'hashedPublicKey': hashedPublicKey,
        'privateKey': privateKey,
        'name': name,
        'accessoryId': accessoryId,
        'enabled': enabled,
      };
}

class ArchivedDeviceStatus {
  final String hashedPublicKey;
  final String name;
  final String? accessoryId;
  final bool enabled;

  const ArchivedDeviceStatus({
    required this.hashedPublicKey,
    required this.name,
    required this.accessoryId,
    required this.enabled,
  });

  static ArchivedDeviceStatus fromJson(Map<String, dynamic> json) {
    return ArchivedDeviceStatus(
      hashedPublicKey: json['hashedPublicKey'],
      name: json['name'],
      accessoryId: json['accessoryId'],
      enabled: json['enabled'],
    );
  }
}

/// Reads and writes which devices have server-side location-history
/// archiving enabled, via the endpoint's `/history/devices` API.
class HistoryArchiveService {
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

  static void _checkStatus(int statusCode) {
    if (statusCode == 401) {
      throw Exception("Authentication failure. User/password wrong");
    }
    if (statusCode != 200) {
      throw Exception("History archiving request failed with statusCode:$statusCode");
    }
  }

  /// Enables or disables server-side archiving for [devices] in one request.
  /// Throws [Exception] if the server does not confirm success.
  static Future<void> setDevicesArchiving(
      String url, String user, String pass, List<HistoryDeviceEntry> devices,
      {http.Client? client}) async {
    var effectiveClient = client ?? _createClient();
    try {
      var authHeader = _authHeader(user, pass);
      var headers = {
        "Content-Type": "application/json",
        if (authHeader != null) "Authorization": authHeader,
      };
      var body = jsonEncode({'devices': devices.map((d) => d.toJson()).toList()});

      var response = await effectiveClient.post(Uri.parse('$url/history/devices'), headers: headers, body: body);
      _checkStatus(response.statusCode);
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }

  /// Fetches the current server-side archiving status for every device the
  /// server currently knows about.
  static Future<List<ArchivedDeviceStatus>> getArchivedDevices(String url, String user, String pass,
      {http.Client? client}) async {
    var effectiveClient = client ?? _createClient();
    try {
      var authHeader = _authHeader(user, pass);
      var headers = {
        if (authHeader != null) "Authorization": authHeader,
      };

      var response = await effectiveClient.get(Uri.parse('$url/history/devices'), headers: headers);
      _checkStatus(response.statusCode);

      var decoded = jsonDecode(response.body);
      List devices = decoded['devices'];
      return devices.map((d) => ArchivedDeviceStatus.fromJson(d)).toList();
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }
}
