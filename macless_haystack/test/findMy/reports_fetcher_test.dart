import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:macless_haystack/findMy/reports_fetcher.dart';
import 'package:test/test.dart';

void main() {
  const url = 'https://example.com';

  test('fetchLocationReports posts ids/days/force and returns results', () async {
    Map<String, dynamic>? capturedBody;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      expect(request.url.toString(), url);
      expect(request.method, 'POST');
      return http.Response(
        jsonEncode({
          "results": [
            {"id": "key-a"},
          ],
          "new_count": 1,
        }),
        200,
      );
    });

    var result = await ReportsFetcher.fetchLocationReports(
      ['key-a'],
      7,
      url,
      '',
      '',
      client: client,
    );

    expect(capturedBody, {'ids': ['key-a'], 'days': 7, 'force': false});
    expect(result.reports, [
      {"id": "key-a"},
    ]);
    expect(result.newCount, 1);
  });

  test('fetchLocationReports reports appleSessionStale false when the server omits it', () async {
    var client = MockClient(
      (request) async => http.Response(jsonEncode({"results": [], "new_count": 0}), 200),
    );

    var result = await ReportsFetcher.fetchLocationReports(['key-a'], 7, url, '', '', client: client);

    expect(result.appleSessionStale, false);
  });

  test('fetchLocationReports reports appleSessionStale true when the server flags it', () async {
    var client = MockClient(
      (request) async => http.Response(
        jsonEncode({"results": [], "new_count": 0, "appleSessionStale": true}),
        200,
      ),
    );

    var result = await ReportsFetcher.fetchLocationReports(['key-a'], 7, url, '', '', client: client);

    expect(result.appleSessionStale, true);
  });

  test('fetchLocationReports throws AppleSessionExpiredException on a 503 apple_session_expired body',
      () async {
    var client = MockClient(
      (request) async => http.Response(jsonEncode({"error": "apple_session_expired"}), 503),
    );

    expect(
      () => ReportsFetcher.fetchLocationReports(['key-a'], 7, url, '', '', client: client),
      throwsA(isA<AppleSessionExpiredException>()),
    );
  });

  test('fetchLocationReports throws a generic exception on an unrelated 503 body', () async {
    var client = MockClient((request) async => http.Response('service unavailable', 503));

    expect(
      () => ReportsFetcher.fetchLocationReports(['key-a'], 7, url, '', '', client: client),
      throwsA(isNot(isA<AppleSessionExpiredException>())),
    );
  });

  test('fetchLocationReports throws on a 401', () async {
    var client = MockClient((request) async => http.Response('', 401));

    expect(
      () => ReportsFetcher.fetchLocationReports(['key-a'], 7, url, '', '', client: client),
      throwsException,
    );
  });
}
