import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'auth_scaffold.dart';

/// Shown after sign up when the project requires email confirmation
/// (signUp returned a user but no session). The user must verify via the link
/// in their inbox, then come back and sign in — there is no path into the app
/// without a real authenticated session.
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({
    super.key,
    required this.authService,
    required this.email,
    required this.onContinueToLogin,
    required this.onBackToSignIn,
  });

  final AuthService authService;
  final String email;

  /// "I have verified, continue to login" — routes to the sign in screen.
  final VoidCallback onContinueToLogin;
  final VoidCallback onBackToSignIn;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  bool _resending = false;
  String? _error;

  Future<void> _resend() async {
    setState(() {
      _resending = true;
      _error = null;
    });
    try {
      await widget.authService.resendConfirmationEmail(widget.email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verification email re-sent to ${widget.email}.')),
        );
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not resend right now. Try again later.');
      }
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Verify your email',
      subtitle: 'One quick step before you can sign in.',
      error: _error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                const Icon(Icons.mark_email_unread_outlined,
                    size: 40, color: Color(0xFF1D4ED8)),
                const SizedBox(height: 12),
                const Text(
                  'We sent a verification link to',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.email,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Text(
                  'Open the link to confirm your account (check your spam '
                  'folder too). After clicking it, return here and sign in — '
                  "you're only signed in once login succeeds.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: widget.onContinueToLogin,
            child: const Text('I verified, go to sign in'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _resending ? null : _resend,
            icon: _resending
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: const Text('Resend verification email'),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: widget.onBackToSignIn,
            child: const Text('Back to sign in'),
          ),
        ],
      ),
    );
  }
}
