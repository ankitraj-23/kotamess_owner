import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'auth_scaffold.dart';

/// Collects everything needed to create an owner account, exactly once.
///
/// Owner/mess names are written to Supabase user metadata during sign up, so
/// the profile row can be created automatically later — the user is never asked
/// for these details a second time.
///
/// Outcome routing:
///   * session returned (email confirmation OFF) -> [AuthGate] sees the session
///     and enters the app; this screen does nothing further.
///   * user but no session (email confirmation ON) -> [onAwaitingVerification].
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({
    super.key,
    required this.authService,
    required this.onNeedSignIn,
    required this.onAwaitingVerification,
  });

  final AuthService authService;
  final VoidCallback onNeedSignIn;
  final ValueChanged<String> onAwaitingVerification;

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  static const _minPasswordLength = 8;

  final _formKey = GlobalKey<FormState>();
  final _ownerName = TextEditingController();
  final _messName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ownerName.dispose();
    _messName.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await widget.authService.signUp(
        email: _email.text,
        password: _password.text,
        ownerName: _ownerName.text,
        messName: _messName.text,
      );
      if (!mounted) return;

      switch (outcome) {
        case SignUpOutcome.signedIn:
          // Email confirmation is OFF: AuthGate picks up the session and the
          // profile is created from metadata on entry. Nothing to do here.
          break;
        case SignUpOutcome.needsVerification:
          // Email confirmation is ON: must verify before signing in.
          widget.onAwaitingVerification(_email.text.trim());
        case SignUpOutcome.alreadyExists:
          setState(() => _error =
              'An account may already exist for this email. Please sign in '
              'instead, or reset your password.');
        case SignUpOutcome.unknown:
          setState(() => _error = 'Could not create the account. Try again.');
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create owner account',
      subtitle: 'Set up your mess so requests stay scoped to you.',
      error: _error,
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            TextFormField(
              controller: _ownerName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your name',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _messName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Mess name',
                prefixIcon: Icon(Icons.storefront_outlined),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Enter your mess name'
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: (v) =>
                  (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(
                labelText: 'Password',
                helperText: 'At least $_minPasswordLength characters',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: (v) => (v == null || v.length < _minPasswordLength)
                  ? 'Use at least $_minPasswordLength characters'
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _confirmPassword,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(
                labelText: 'Confirm password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: (v) =>
                  (v != _password.text) ? 'Passwords do not match' : null,
              onFieldSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create account'),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : widget.onNeedSignIn,
              child: const Text('Already have an account? Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
