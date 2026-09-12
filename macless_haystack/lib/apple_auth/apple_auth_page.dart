import 'package:flutter/material.dart';
import 'package:macless_haystack/apple_auth/apple_auth_service.dart';

/// Login wizard for the server's Apple ID session: username/password,
/// then (if Apple requires it) a 2FA code. Pops `true` on success so the
/// caller can refresh its own status display.
class AppleAuthPage extends StatefulWidget {
  final String endpointUrl;
  final String endpointUser;
  final String endpointPass;

  const AppleAuthPage({
    super.key,
    required this.endpointUrl,
    required this.endpointUser,
    required this.endpointPass,
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

  _AppleAuthStep _step = _AppleAuthStep.credentials;
  AppleAuthMethod? _method;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
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
      );
      if (!mounted) return;
      if (result.authenticated) {
        Navigator.of(context).pop(true);
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
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // A wrong/expired code, or a dropped pending login, both require
        // starting over from the username/password step (per the design:
        // no retry-the-same-code loop).
        _step = _AppleAuthStep.credentials;
        _error = _describeError(e);
        _submitting = false;
      });
    }
  }

  String _methodLabel() {
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 8),
                    ],
                    TextFormField(
                      controller: _usernameController,
                      decoration: const InputDecoration(labelText: 'Apple ID'),
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your Apple ID' : null,
                    ),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _submitting ? null : _submitCredentials,
                      child: _submitting
                          ? const SizedBox(
                              height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Log in'),
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 8),
                  ],
                  Text(_methodLabel()),
                  TextField(
                    controller: _codeController,
                    decoration: const InputDecoration(labelText: '2FA code'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _submitting ? null : _submitCode,
                    child: _submitting
                        ? const SizedBox(
                            height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Submit code'),
                  ),
                ],
              ),
      ),
    );
  }
}
