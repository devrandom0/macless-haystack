import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:macless_haystack/history/history_archive_service.dart';
import 'package:test/test.dart';

void main() {
  const url = 'http://localhost:6176';
  const device = HistoryDeviceEntry(
    hashedPublicKey: 'hash-a',
    privateKey: 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==',
    name: 'Keys',
    accessoryId: 'acc-1',
    enabled: true,
  );

  test('setDevicesArchiving posts the device list as JSON', () async {
    Map<String, dynamic>? capturedBody;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      expect(request.url.toString(), '$url/history/devices');
      expect(request.method, 'POST');
      return http.Response('{"status":"ok"}', 200);
    });

    await HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client);

    expect(capturedBody, {
      'devices': [
        {
          'hashedPublicKey': 'hash-a',
          'privateKey': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==',
          'name': 'Keys',
          'accessoryId': 'acc-1',
          'enabled': true,
        }
      ]
    });
  });

  test('setDevicesArchiving sends a basic auth header when credentials are set', () async {
    String? authHeader;
    var client = MockClient((request) async {
      authHeader = request.headers['Authorization'];
      return http.Response('{"status":"ok"}', 200);
    });

    await HistoryArchiveService.setDevicesArchiving(url, 'user', 'pass', [device], client: client);

    expect(authHeader, 'Basic ${base64.encode(utf8.encode('user:pass'))}');
  });

  test('setDevicesArchiving omits the auth header when credentials are empty', () async {
    String? authHeader = 'unset';
    var client = MockClient((request) async {
      authHeader = request.headers['Authorization'];
      return http.Response('{"status":"ok"}', 200);
    });

    await HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client);

    expect(authHeader, isNull);
  });

  test('setDevicesArchiving throws on a non-200 response', () async {
    var client = MockClient((request) async => http.Response('error', 500));

    expect(
      () => HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client),
      throwsException,
    );
  });

  test('setDevicesArchiving throws a specific message on 401', () async {
    var client = MockClient((request) async => http.Response('', 401));

    expect(
      () => HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client),
      throwsA(predicate((e) => e is Exception && e.toString().contains('Authentication failure'))),
    );
  });

  test('getArchivedDevices sends a GET request and parses the device list', () async {
    var client = MockClient((request) async {
      expect(request.url.toString(), '$url/history/devices');
      expect(request.method, 'GET');
      return http.Response(
        jsonEncode({
          'devices': [
            {
              'hashedPublicKey': 'hash-a',
              'name': 'Keys',
              'accessoryId': 'acc-1',
              'enabled': true,
              'pollIntervalHours': 4,
              'retentionDays': 30,
            },
          ]
        }),
        200,
      );
    });

    var devices = await HistoryArchiveService.getArchivedDevices(url, '', '', client: client);

    expect(devices.length, 1);
    expect(devices.first.hashedPublicKey, 'hash-a');
    expect(devices.first.name, 'Keys');
    expect(devices.first.accessoryId, 'acc-1');
    expect(devices.first.enabled, true);
  });

  test('getArchivedDevices throws on a non-200 response', () async {
    var client = MockClient((request) async => http.Response('error', 500));

    expect(
      () => HistoryArchiveService.getArchivedDevices(url, '', '', client: client),
      throwsException,
    );
  });

  test('HistoryDeviceEntry omits pollIntervalHours and retentionDays when null', () {
    expect(device.toJson().containsKey('pollIntervalHours'), false);
    expect(device.toJson().containsKey('retentionDays'), false);
  });

  test('HistoryDeviceEntry includes pollIntervalHours and retentionDays when set', () {
    const withOverrides = HistoryDeviceEntry(
      hashedPublicKey: 'hash-a',
      privateKey: 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==',
      name: 'Keys',
      accessoryId: 'acc-1',
      enabled: true,
      pollIntervalHours: 12,
      retentionDays: 60,
    );

    expect(withOverrides.toJson()['pollIntervalHours'], 12);
    expect(withOverrides.toJson()['retentionDays'], 60);
  });

  test('setDevicesArchiving omits pollIntervalHours/retentionDays from the request body when null', () async {
    Map<String, dynamic>? capturedBody;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      return http.Response('{"status":"ok"}', 200);
    });

    await HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client);

    var sentDevice = capturedBody!['devices'][0] as Map<String, dynamic>;
    expect(sentDevice.containsKey('pollIntervalHours'), false);
    expect(sentDevice.containsKey('retentionDays'), false);
  });

  test('ArchivedDeviceStatus.fromJson reads pollIntervalHours and retentionDays', () async {
    var client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'devices': [
            {
              'hashedPublicKey': 'hash-a',
              'name': 'Keys',
              'accessoryId': 'acc-1',
              'enabled': true,
              'pollIntervalHours': 8,
              'retentionDays': 90,
            },
          ]
        }),
        200,
      );
    });

    var devices = await HistoryArchiveService.getArchivedDevices(url, '', '', client: client);

    expect(devices.first.pollIntervalHours, 8);
    expect(devices.first.retentionDays, 90);
  });

  test('ArchivedDeviceStatus.fromJson rounds a fractional pollIntervalHours from the server', () async {
    // The server stores pollIntervalHours uncoerced, so a fractional hour
    // value (e.g. saved as 1.5) comes back as a JSON float, not an int.
    var client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'devices': [
            {
              'hashedPublicKey': 'hash-a',
              'name': 'Keys',
              'accessoryId': 'acc-1',
              'enabled': true,
              'pollIntervalHours': 1.5,
              'retentionDays': 90,
            },
          ]
        }),
        200,
      );
    });

    var devices = await HistoryArchiveService.getArchivedDevices(url, '', '', client: client);

    expect(devices.first.pollIntervalHours, 2);
  });
}
