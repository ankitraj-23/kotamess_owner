import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'auth_scaffold.dart';

/// Email + password sign in. On success the [AuthService] session stream fires
/// and the [AuthGate] swaps over to the app automatically.
class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.authService,
    required this.onNeedSignUp,
    required this.onEmailNotConfirmed,
  });

  final AuthService authService;
  final VoidCallback onNeedSignUp;

  /// Called when the user wants to go to the verify-email screen for [email]
  /// (because Supabase rejected sign in as unverified).
  final ValueChanged<String> onEmailNotConfirmed;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  /// Set to the entered email when sign in fails because it is unverified, so
  /// we can offer a "Verify email" shortcut.
  String? _unverifiedEmail;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _unverifiedEmail = null;
    });
    try {
      await widget.authService.signIn(
        email: _email.text,
        password: _password.text,
      );
      // No navigation here: AuthGate listens to the session stream.
    } on AuthException catch (e) {
      if (!mounted) return;
      if (widget.authService.isEmailNotConfirmed(e)) {
        setState(() {
          _unverifiedEmail = _email.text.trim();
          _error = 'Please verify your email first. Check inbox/spam or '
              'resend the verification email.';
        });
        return;
      }
      setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final controller = TextEditingController(text: _email.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Enter your account email and we'll send a reset link.",
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.mail_outline),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Send reset link'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (email == null || email.isEmpty || !email.contains('@')) return;
    try {
      await widget.authService.sendPasswordReset(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Password reset link sent to $email (check spam).'),
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not send reset link. Try again later.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Sign in to manage your mess requests.',
      error: _error,
      child: Form(
        key: _formKey,
        child: Column(
          children: [
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
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: (v) =>
                  (v == null || v.isEmpty) ? 'Enter your password' : null,
              onFieldSubmitted: (_) => _busy ? null : _submit(),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : _forgotPassword,
                child: const Text('Forgot password?'),
              ),
            ),
            const SizedBox(height: 8),
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
                    : const Text('Sign in'),
              ),
            ),
            if (_unverifiedEmail != null) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => widget.onEmailNotConfirmed(_unverifiedEmail!),
                  icon: const Icon(Icons.mark_email_unread_outlined),
                  label: const Text('Verify email'),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : widget.onNeedSignUp,
              child: const Text('New here? Create an owner account'),
            ),
          ],
        ),
      ),
    );
  }
}
