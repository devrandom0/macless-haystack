import 'package:flutter/material.dart';
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

  const AppleAuthPage({
    super.key,
    required this.endpointUrl,
    required this.endpointUser,
    required this.endpointPass,
    this.initialLoggedIn = false,
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
  bool _loggingOut = false;
  String? _error;
  late bool _showLoggedInHint;

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
    super.dispose();
  }

  Future<void> _logout() async {
    setState(() {
      _loggingOut = true;
      _error = null;
    });
    try {
      await AppleAuthService.logout(widget.endpointUrl, widget.endpointUser, widget.endpointPass);
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
    });
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
                        ),
                        obscureText: true,
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
                    onPressed: (_submitting || _loggingOut) ? null : _submitCode,
                    child: _submitting
                        ? const SizedBox(
                            height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Submit code'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _submitting ? null : _useDifferentAppleId,
                    child: const Text('Use a different Apple ID'),
                  ),
                ],
              ),
      ),
    );
  }
}
