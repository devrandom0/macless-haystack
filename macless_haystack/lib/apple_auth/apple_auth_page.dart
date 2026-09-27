import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:macless_haystack/apple_auth/apple_auth_service.dart';

/// Login wizard for the server's Apple ID session: username/password,
/// then (if Apple requires it) a 2FA code, or a log-out action. The caller
/// is expected to refresh its own status display whenever this page is
/// popped, by any route (login success, logout, or just navigating back) -
/// there's no reliable way to distinguish those from the pop alone, since
/// the system back gesture bypasses any in-page pop-value plumbing.
class AppleAuthPage extends StatefulWidget {
  final String endpointUrl;
  final String endpointUser;
  final String endpointPass;

  /// Whether the server currently reports a valid Apple session, per the
  /// caller's own status check. Purely cosmetic - only used to show a
  /// placeholder hint in the credentials fields, never affects behavior.
  final bool initialLoggedIn;

  /// Overrides the HTTP client used for every AppleAuthService call. Only
  /// meant for tests - production always leaves this null.
  final http.Client? httpClient;

  const AppleAuthPage({
    super.key,
    required this.endpointUrl,
    required this.endpointUser,
    required this.endpointPass,
    this.initialLoggedIn = false,
    this.httpClient,
  });

  @override
  State<AppleAuthPage> createState() => _AppleAuthPageState();
}

enum _AppleAuthStep { credentials, code }

class _AppleAuthPageState extends State<AppleAuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();

  static const _resendCooldown = Duration(seconds: 30);

  _AppleAuthStep _step = _AppleAuthStep.credentials;
  AppleAuthMethod? _method;
  bool _submitting = false;
  bool _loggingOut = false;
  bool _obscurePassword = true;
  String? _error;
  late bool _showLoggedInHint;

  bool _resending = false;
  String? _resendPhone;
  AppleResendMode? _resendMode;
  DateTime? _resendCooldownUntil;
  Timer? _resendCooldownTimer;
  // Bumped by _resetResendState so a resend response that arrives after the
  // step already moved on (a different login attempt, or back to
  // credentials) is recognized as stale and ignored.
  int _resendGeneration = 0;

  @override
  void initState() {
    super.initState();
    _showLoggedInHint = widget.initialLoggedIn;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    _resendCooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _logout() async {
    setState(() {
      _loggingOut = true;
      _error = null;
    });
    try {
      await AppleAuthService.logout(widget.endpointUrl, widget.endpointUser, widget.endpointPass,
          client: widget.httpClient);
      if (!mounted) return;
      setState(() {
        _showLoggedInHint = false;
        _loggingOut = false;
        _usernameController.clear();
        _passwordController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logged out')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describeError(e);
        _loggingOut = false;
      });
    }
  }

  String _describeError(Object e) {
    if (e is AppleAuthHttpsRequiredException) {
      return e.toString();
    }
    if (e is AppleAuthException) {
      switch (e.errorCode) {
        case 'invalid_credentials':
          return 'Incorrect Apple ID or password.';
        case 'invalid_code':
          return 'Incorrect code. Please log in again.';
        case 'no_pending_login':
        case 'login_expired':
          return 'This login attempt expired. Please log in again.';
        case 'apple_unreachable':
          return "Couldn't reach Apple. Please try again.";
        case 'account_error':
          return e.message ?? 'Apple rejected this account.';
        case 'no_trusted_phone':
          return 'Apple has no trusted phone number on file for this account.';
        case 'invalid_mode':
        case 'invalid_phone_id':
          return "Couldn't request a new code. Please try again.";
        case 'resend_too_soon':
          return 'Please wait a moment before requesting another code.';
        case 'too_many_resends':
          return 'Too many code requests. Please log in again.';
        case 'apple_refused_code':
          return "Apple couldn't send a new code right now. Please try again.";
        case 'apple_page_unrecognized':
          return "Couldn't reach Apple's verification page. Please try again.";
        default:
          return e.message ?? 'Login failed.';
      }
    }
    return 'Login failed: $e';
  }

  Future<void> _submitCredentials() async {
    if (_formKey.currentState?.validate() != true) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      var result = await AppleAuthService.login(
        widget.endpointUrl, widget.endpointUser, widget.endpointPass,
        _usernameController.text.trim(), _passwordController.text,
        client: widget.httpClient,
      );
      if (!mounted) return;
      if (result.authenticated) {
        _resetResendState();
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _step = _AppleAuthStep.code;
        _method = result.codeRequiredMethod;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describeError(e);
        _submitting = false;
      });
    }
  }

  void _useDifferentAppleId() {
    setState(() {
      _step = _AppleAuthStep.credentials;
      _error = null;
      // Otherwise a second login attempt that also needs 2FA shows the
      // previous attempt's now-stale code pre-filled.
      _codeController.clear();
      _method = null;
      _resetResendState();
    });
  }

  /// Clears the resend hint/cooldown/timer and invalidates any resend
  /// request still in flight, so its response is ignored if it arrives
  /// after the step has moved on. Called whenever the code step is left
  /// (back to credentials, or a completed login) and on a fresh attempt.
  void _resetResendState() {
    _resendGeneration++;
    _resendCooldownTimer?.cancel();
    _resendCooldownTimer = null;
    _resending = false;
    _resendPhone = null;
    _resendMode = null;
    _resendCooldownUntil = null;
  }

  bool get _resendOnCooldown =>
      _resendCooldownUntil != null && DateTime.now().isBefore(_resendCooldownUntil!);

  Future<void> _resendCode(AppleResendMode mode) async {
    if (_resending || _resendOnCooldown) return;
    final generation = _resendGeneration;
    setState(() {
      _resending = true;
      _error = null;
    });
    try {
      var result = await AppleAuthService.resendCode(
        widget.endpointUrl, widget.endpointUser, widget.endpointPass, mode,
        client: widget.httpClient,
      );
      if (!mounted || generation != _resendGeneration) return;
      _resendCooldownTimer?.cancel();
      var cooldownUntil = DateTime.now().add(_resendCooldown);
      _resendCooldownTimer = Timer(_resendCooldown, () {
        if (mounted && generation == _resendGeneration) setState(() {});
      });
      setState(() {
        _resending = false;
        _resendMode = result.method;
        _resendPhone = result.phone;
        _resendCooldownUntil = cooldownUntil;
      });
    } catch (e) {
      if (!mounted || generation != _resendGeneration) return;
      setState(() {
        _resending = false;
        _error = _describeError(e);
      });
    }
  }

  Future<void> _submitCode() async {
    if (_codeController.text.trim().isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await AppleAuthService.verifyCode(
        widget.endpointUrl, widget.endpointUser, widget.endpointPass,
        _codeController.text.trim(),
        client: widget.httpClient,
      );
      if (!mounted) return;
      _resetResendState();
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // A wrong/expired code, or a dropped pending login, both require
        // starting over from the username/password step (per the design:
        // no retry-the-same-code loop).
        _step = _AppleAuthStep.credentials;
        _error = _describeError(e);
        _submitting = false;
        _resetResendState();
      });
    }
  }

  String _methodLabel() {
    if (_resendMode == AppleResendMode.voice) {
      return _resendPhone != null
          ? "You'll get a call at ${_resendPhone!}"
          : "You'll get a call with your code";
    }
    if (_resendMode == AppleResendMode.sms) {
      return _resendPhone != null
          ? 'Code sent by SMS to ${_resendPhone!}'
          : 'Code sent by SMS';
    }
    return _method == AppleAuthMethod.trustedDevice
        ? 'Enter the code shown on your trusted device'
        : 'Enter the SMS code sent to your phone';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in to Apple ID')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _step == _AppleAuthStep.credentials
            ? Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline, color: Theme.of(context).colorScheme.onErrorContainer),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (_showLoggedInHint) ...[
                        Text(
                          'Already logged in. Log in again to switch accounts or test the login flow, '
                          'or log out below.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                      ],
                      TextFormField(
                        controller: _usernameController,
                        decoration: InputDecoration(
                          labelText: 'Apple ID',
                          hintText: _showLoggedInHint ? 'Already logged in' : null,
                        ),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.username],
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your Apple ID' : null,
                      ),
                      TextFormField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          hintText: _showLoggedInHint ? '••••••••' : null,
                          suffixIcon: IconButton(
                            tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                            icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        obscureText: _obscurePassword,
                        autofillHints: const [AutofillHints.password],
                        validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: (_submitting || _loggingOut) ? null : _submitCredentials,
                        child: _submitting
                            ? const SizedBox(
                                height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Log in'),
                      ),
                      if (_showLoggedInHint) ...[
                        const SizedBox(height: 24),
                        const Divider(),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: (_submitting || _loggingOut) ? null : _logout,
                          child: _loggingOut
                              ? const SizedBox(
                                  height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Log out'),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text('Verifying ${_usernameController.text.trim()}'),
                  const SizedBox(height: 8),
                  Text(_methodLabel()),
                  TextField(
                    controller: _codeController,
                    decoration: const InputDecoration(labelText: '2FA code'),
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: (_submitting || _loggingOut || _resending) ? null : _submitCode,
                    child: _submitting
                        ? const SizedBox(
                            height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Submit code'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: (_submitting || _resending || _resendOnCooldown)
                              ? null
                              : () => _resendCode(AppleResendMode.sms),
                          child: const Text('Text me instead'),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: (_submitting || _resending || _resendOnCooldown)
                              ? null
                              : () => _resendCode(AppleResendMode.voice),
                          child: const Text('Call me instead'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: (_submitting || _resending) ? null : _useDifferentAppleId,
                    child: const Text('Use a different Apple ID'),
                  ),
                ],
              ),
      ),
    );
  }
}
