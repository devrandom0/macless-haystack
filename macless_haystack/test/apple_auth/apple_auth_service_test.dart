import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:macless_haystack/apple_auth/apple_auth_service.dart';
import 'package:test/test.dart';

void main() {
  const httpsUrl = 'https://example.com';
  const httpUrl = 'http://localhost:6176';

  test('login throws AppleAuthHttpsRequiredException and makes no request over http', () async {
    var client = MockClient((request) async {
      fail('should not make a network request when the endpoint URL is not https');
    });

    expect(
      () => AppleAuthService.login(httpUrl, '', '', 'id@example.com', 'hunter2', client: client),
      throwsA(isA<AppleAuthHttpsRequiredException>()),
    );
  });

  test('verifyCode throws AppleAuthHttpsRequiredException and makes no request over http', () async {
    var client = MockClient((request) async {
      fail('should not make a network request when the endpoint URL is not https');
    });

    expect(
      () => AppleAuthService.verifyCode(httpUrl, '', '', '123456', client: client),
      throwsA(isA<AppleAuthHttpsRequiredException>()),
    );
  });

  test('login posts credentials and returns authenticated on immediate success', () async {
    Map<String, dynamic>? capturedBody;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      expect(request.url.toString(), '$httpsUrl/auth/apple/login');
      expect(request.method, 'POST');
      return http.Response('{"status":"authenticated"}', 200);
    });

    var result = await AppleAuthService.login(httpsUrl, '', '', 'id@example.com', 'hunter2', client: client);

    expect(result.authenticated, true);
    expect(capturedBody, {'username': 'id@example.com', 'password': 'hunter2'});
  });

  test('login returns codeRequired with the parsed sms method', () async {
    var client = MockClient((request) async => http.Response('{"status":"code_required","method":"sms"}', 200));

    var result = await AppleAuthService.login(httpsUrl, '', '', 'id@example.com', 'hunter2', client: client);

    expect(result.authenticated, false);
    expect(result.codeRequiredMethod, AppleAuthMethod.sms);
  });

  test('login returns codeRequired with the parsed trusted_device method', () async {
    var client = MockClient(
        (request) async => http.Response('{"status":"code_required","method":"trusted_device"}', 200));

    var result = await AppleAuthService.login(httpsUrl, '', '', 'id@example.com', 'hunter2', client: client);

    expect(result.codeRequiredMethod, AppleAuthMethod.trustedDevice);
  });

  test('login throws AppleAuthException with the server error code on 401', () async {
    var client = MockClient((request) async => http.Response('{"error":"invalid_credentials"}', 401));

    expect(
      () => AppleAuthService.login(httpsUrl, '', '', 'id@example.com', 'wrong', client: client),
      throwsA(predicate((e) => e is AppleAuthException && e.errorCode == 'invalid_credentials')),
    );
  });

  test('verifyCode posts the code and sends a basic auth header', () async {
    Map<String, dynamic>? capturedBody;
    String? authHeader;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      authHeader = request.headers['Authorization'];
      return http.Response('{"status":"authenticated"}', 200);
    });

    await AppleAuthService.verifyCode(httpsUrl, 'user', 'pass', '654321', client: client);

    expect(capturedBody, {'code': '654321'});
    expect(authHeader, 'Basic ${base64.encode(utf8.encode('user:pass'))}');
  });

  test('verifyCode throws AppleAuthException on an invalid code', () async {
    var client = MockClient((request) async => http.Response('{"error":"invalid_code"}', 401));

    expect(
      () => AppleAuthService.verifyCode(httpsUrl, '', '', '000000', client: client),
      throwsA(predicate((e) => e is AppleAuthException && e.errorCode == 'invalid_code')),
    );
  });

  test('getStatus parses loggedIn and pending', () async {
    var client = MockClient((request) async {
      expect(request.url.toString(), '$httpUrl/auth/apple/status');
      expect(request.method, 'GET');
      return http.Response('{"loggedIn":true,"pending":false}', 200);
    });

    var status = await AppleAuthService.getStatus(httpUrl, '', '', client: client);

    expect(status.loggedIn, true);
    expect(status.pending, false);
  });

  test('getStatus throws on a non-200 response', () async {
    var client = MockClient((request) async => http.Response('error', 500));

    expect(
      () => AppleAuthService.getStatus(httpUrl, '', '', client: client),
      throwsException,
    );
  });

  test('resendCode throws AppleAuthHttpsRequiredException and makes no request over http', () async {
    var client = MockClient((request) async {
      fail('should not make a network request when the endpoint URL is not https');
    });

    expect(
      () => AppleAuthService.resendCode(httpUrl, '', '', AppleResendMode.sms, client: client),
      throwsA(isA<AppleAuthHttpsRequiredException>()),
    );
  });

  test('resendCode posts the requested mode and returns the parsed result', () async {
    Map<String, dynamic>? capturedBody;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      expect(request.url.toString(), '$httpsUrl/auth/apple/resend');
      expect(request.method, 'POST');
      return http.Response('{"status":"code_required","method":"sms","phone":"+1 ***1234"}', 200);
    });

    var result = await AppleAuthService.resendCode(httpsUrl, '', '', AppleResendMode.sms, client: client);

    expect(capturedBody, {'mode': 'sms'});
    expect(result.method, AppleResendMode.sms);
    expect(result.phone, '+1 ***1234');
  });

  test('resendCode posts voice mode and tolerates a null phone', () async {
    Map<String, dynamic>? capturedBody;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      return http.Response('{"status":"code_required","method":"voice","phone":null}', 200);
    });

    var result = await AppleAuthService.resendCode(httpsUrl, '', '', AppleResendMode.voice, client: client);

    expect(capturedBody, {'mode': 'voice'});
    expect(result.method, AppleResendMode.voice);
    expect(result.phone, null);
  });

  test('resendCode throws AppleAuthException with the server error code on failure', () async {
    var client = MockClient((request) async => http.Response('{"error":"no_trusted_phone"}', 400));

    expect(
      () => AppleAuthService.resendCode(httpsUrl, '', '', AppleResendMode.sms, client: client),
      throwsA(predicate((e) => e is AppleAuthException && e.errorCode == 'no_trusted_phone')),
    );
  });

  test('resendCode throws AppleAuthException (not a TypeError) when method is missing', () async {
    var client = MockClient((request) async => http.Response('{"status":"code_required","phone":null}', 200));

    expect(
      () => AppleAuthService.resendCode(httpsUrl, '', '', AppleResendMode.sms, client: client),
      throwsA(isA<AppleAuthException>()),
    );
  });

  test('resendCode throws AppleAuthException (not a TypeError) when method is not a string', () async {
    var client = MockClient(
        (request) async => http.Response('{"status":"code_required","method":7,"phone":null}', 200));

    expect(
      () => AppleAuthService.resendCode(httpsUrl, '', '', AppleResendMode.sms, client: client),
      throwsA(isA<AppleAuthException>()),
    );
  });

  test('logout posts to /auth/apple/logout with basic auth', () async {
    String? authHeader;
    var client = MockClient((request) async {
      expect(request.url.toString(), '$httpUrl/auth/apple/logout');
      expect(request.method, 'POST');
      authHeader = request.headers['Authorization'];
      return http.Response('{"status":"logged_out"}', 200);
    });

    await AppleAuthService.logout(httpUrl, 'user', 'pass', client: client);

    expect(authHeader, 'Basic ${base64.encode(utf8.encode('user:pass'))}');
  });

  test('logout does not require https', () async {
    var client = MockClient((request) async => http.Response('{"status":"logged_out"}', 200));

    await AppleAuthService.logout(httpUrl, '', '', client: client);
  });

  test('logout throws AppleAuthException on a non-200 response', () async {
    var client = MockClient((request) async => http.Response('{"error":"logout_failed"}', 500));

    expect(
      () => AppleAuthService.logout(httpUrl, '', '', client: client),
      throwsA(predicate((e) => e is AppleAuthException && e.errorCode == 'logout_failed')),
    );
  });
}
