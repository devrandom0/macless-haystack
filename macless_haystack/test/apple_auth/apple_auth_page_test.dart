import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:macless_haystack/apple_auth/apple_auth_page.dart';

/// Drives an AppleAuthPage from the credentials step to the code step, via
/// a MockClient that always reports a second factor is required.
Future<void> _pumpToCodeStep(
  WidgetTester tester, {
  required http.Client client,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => AppleAuthPage(
                  endpointUrl: 'https://example.com',
                  endpointUser: '',
                  endpointPass: '',
                  httpClient: client,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.widgetWithText(ElevatedButton, 'open'));
  await tester.pumpAndSettle();

  await tester.enterText(find.widgetWithText(TextFormField, 'Apple ID'), 'id@example.com');
  await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'hunter2');
  await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('code step shows Text me instead and Call me instead buttons', (tester) async {
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"sms"}', 200);
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);

    expect(find.widgetWithText(TextButton, 'Text me instead'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Call me instead'), findsOneWidget);
  });

  testWidgets('tapping Text me instead requests an SMS resend and updates the hint', (tester) async {
    var resendRequests = <Map<String, dynamic>>[];
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"trusted_device"}', 200);
      }
      if (request.url.path == '/auth/apple/resend') {
        resendRequests.add(jsonDecode(request.body));
        return http.Response('{"status":"code_required","method":"sms","phone":"+1 ***1234"}', 200);
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);
    await tester.tap(find.widgetWithText(TextButton, 'Text me instead'));
    await tester.pumpAndSettle();

    expect(resendRequests, [
      {'mode': 'sms'}
    ]);
    expect(find.text('Code sent by SMS to +1 ***1234'), findsOneWidget);
  });

  testWidgets('tapping Call me instead requests a voice resend and updates the hint', (tester) async {
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"sms"}', 200);
      }
      if (request.url.path == '/auth/apple/resend') {
        return http.Response('{"status":"code_required","method":"voice","phone":"+1 ***1234"}', 200);
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);
    await tester.tap(find.widgetWithText(TextButton, 'Call me instead'));
    await tester.pumpAndSettle();

    expect(find.text("You'll get a call at +1 ***1234"), findsOneWidget);
  });

  testWidgets('resend buttons disable immediately after a successful resend', (tester) async {
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"sms"}', 200);
      }
      if (request.url.path == '/auth/apple/resend') {
        return http.Response('{"status":"code_required","method":"sms","phone":null}', 200);
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);
    await tester.tap(find.widgetWithText(TextButton, 'Text me instead'));
    await tester.pumpAndSettle();

    var textMeButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Text me instead'));
    var callMeButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Call me instead'));
    expect(textMeButton.onPressed, isNull);
    expect(callMeButton.onPressed, isNull);
  });

  testWidgets('a failed resend shows the error banner without disabling the buttons', (tester) async {
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"sms"}', 200);
      }
      if (request.url.path == '/auth/apple/resend') {
        return http.Response('{"error":"no_trusted_phone"}', 400);
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);
    await tester.tap(find.widgetWithText(TextButton, 'Text me instead'));
    await tester.pumpAndSettle();

    expect(find.text('Apple has no trusted phone number on file for this account.'), findsOneWidget);
    var textMeButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Text me instead'));
    expect(textMeButton.onPressed, isNotNull);
  });

  testWidgets('a failed verify after a resend resets the hint and cooldown', (tester) async {
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"trusted_device"}', 200);
      }
      if (request.url.path == '/auth/apple/resend') {
        return http.Response('{"status":"code_required","method":"sms","phone":"+1 ***1234"}', 200);
      }
      if (request.url.path == '/auth/apple/verify') {
        return http.Response('{"error":"invalid_code"}', 401);
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);
    await tester.tap(find.widgetWithText(TextButton, 'Text me instead'));
    await tester.pumpAndSettle();
    expect(find.text('Code sent by SMS to +1 ***1234'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '2FA code'), '000000');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Submit code'));
    await tester.pumpAndSettle();

    // Back on the credentials step - log in again to reach a fresh code step.
    await tester.enterText(find.widgetWithText(TextFormField, 'Apple ID'), 'id@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'hunter2');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter the code shown on your trusted device'), findsOneWidget);
    expect(find.text('Code sent by SMS to +1 ***1234'), findsNothing);
    var textMeButton = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Text me instead'));
    expect(textMeButton.onPressed, isNotNull);
  });

  testWidgets('Submit and Use a different Apple ID disable while a resend is in flight', (tester) async {
    var resendCompleter = Completer<http.Response>();
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"sms"}', 200);
      }
      if (request.url.path == '/auth/apple/resend') {
        return resendCompleter.future;
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);
    await tester.tap(find.widgetWithText(TextButton, 'Text me instead'));
    await tester.pump(); // request started, still pending

    var submitButton = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Submit code'));
    var useOtherIdButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Use a different Apple ID'));
    expect(submitButton.onPressed, isNull);
    expect(useOtherIdButton.onPressed, isNull);

    resendCompleter.complete(http.Response('{"status":"code_required","method":"sms","phone":null}', 200));
    await tester.pumpAndSettle();

    submitButton = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Submit code'));
    expect(submitButton.onPressed, isNotNull);
  });

  testWidgets('a resend response that arrives after the page is gone is ignored', (tester) async {
    // Submit and "Use a different Apple ID" are disabled while resending
    // (see the test above), so the only way to leave mid-resend is the
    // page-level back navigation, which - like the system back gesture -
    // bypasses in-page button state entirely.
    var resendCompleter = Completer<http.Response>();
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"sms"}', 200);
      }
      if (request.url.path == '/auth/apple/resend') {
        return resendCompleter.future;
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);
    await tester.tap(find.widgetWithText(TextButton, 'Text me instead'));
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AppleAuthPage), findsNothing);

    // The response finally arrives after the page is gone - must not throw
    // (setState after dispose) or do anything observable.
    resendCompleter.complete(http.Response('{"status":"code_required","method":"sms","phone":"+1 ***1234"}', 200));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('the 2FA code field keeps working after a resend', (tester) async {
    var client = MockClient((request) async {
      if (request.url.path == '/auth/apple/login') {
        return http.Response('{"status":"code_required","method":"sms"}', 200);
      }
      if (request.url.path == '/auth/apple/resend') {
        return http.Response('{"status":"code_required","method":"voice","phone":"+1 ***1234"}', 200);
      }
      if (request.url.path == '/auth/apple/verify') {
        return http.Response('{"status":"authenticated"}', 200);
      }
      fail('unexpected request to ${request.url.path}');
    });

    await _pumpToCodeStep(tester, client: client);
    await tester.tap(find.widgetWithText(TextButton, 'Call me instead'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '2FA code'), '654321');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Submit code'));
    await tester.pumpAndSettle();

    expect(find.byType(AppleAuthPage), findsNothing);
  });
}
