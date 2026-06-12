import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../main.dart' show KotaShell;
import '../profile/complete_profile_screen.dart';
import '../profile/owner_profile.dart';
import '../profile/owner_profile_service.dart';
import 'auth_service.dart';
import 'sign_in_screen.dart';
import 'sign_up_screen.dart';
import 'verify_email_screen.dart';

/// Top-level router driven by auth state:
///   no session            -> sign in / sign up / verify email
///   session, no profile   -> complete profile (only if metadata is missing)
///   session + profile     -> the app ([KotaShell])
///
/// The main app is reachable ONLY when there is a valid authenticated session,
/// so an unverified sign up (no session) can never enter it.
///
/// Session persistence is automatic (handled by supabase_flutter), so a
/// returning, verified user lands straight on the app.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authService,
    required this.profileService,
  });

  final AuthService authService;
  final OwnerProfileService profileService;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

/// Which screen to show while there is no authenticated session.
enum _AuthView { signIn, signUp, verifyEmail }

class _AuthGateState extends State<AuthGate> {
  _AuthView _view = _AuthView.signIn;
  String _pendingEmail = '';

  void _go(_AuthView view, {String? email}) {
    setState(() {
      _view = view;
      if (email != null) _pendingEmail = email;
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: widget.authService.onAuthStateChange,
      builder: (context, _) {
        // Read the session synchronously rather than from the snapshot event so
        // the very first build (restored session) is handled correctly too.
        if (widget.authService.isSignedIn) {
          return _ProfileGate(
            // Rebuild from scratch when the signed-in user changes.
            key: ValueKey(widget.authService.currentUser?.id),
            authService: widget.authService,
            profileService: widget.profileService,
          );
        }

        switch (_view) {
          case _AuthView.signUp:
            return SignUpScreen(
              authService: widget.authService,
              onNeedSignIn: () => _go(_AuthView.signIn),
              onAwaitingVerification: (email) =>
                  _go(_AuthView.verifyEmail, email: email),
            );
          case _AuthView.verifyEmail:
            return VerifyEmailScreen(
              authService: widget.authService,
              email: _pendingEmail,
              onContinueToLogin: () => _go(_AuthView.signIn),
              onBackToSignIn: () => _go(_AuthView.signIn),
            );
          case _AuthView.signIn:
            return SignInScreen(
              authService: widget.authService,
              onNeedSignUp: () => _go(_AuthView.signUp),
              onEmailNotConfirmed: (email) =>
                  _go(_AuthView.verifyEmail, email: email),
            );
        }
      },
    );
  }
}

/// Resolves the owner profile for the signed-in user and shows the right screen.
/// [OwnerProfileService.resolveOnEntry] creates the profile from sign-up
/// metadata when possible, so [CompleteProfileScreen] only appears when there
/// is genuinely no profile and no metadata to build one from.
class _ProfileGate extends StatefulWidget {
  const _ProfileGate({
    super.key,
    required this.authService,
    required this.profileService,
  });

  final AuthService authService;
  final OwnerProfileService profileService;

  @override
  State<_ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<_ProfileGate> {
  late Future<OwnerProfile?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.profileService.resolveOnEntry();
  }

  void _reload() {
    setState(() {
      _future = widget.profileService.resolveOnEntry();
    });
  }

  Future<void> _signOut() => widget.authService.signOut();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OwnerProfile?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return _ErrorRetry(
            message: 'Could not load your profile.',
            onRetry: _reload,
            onSignOut: _signOut,
          );
        }

        final profile = snapshot.data;
        if (profile == null) {
          // No row and no usable metadata: ask once, then never again.
          return CompleteProfileScreen(
            profileService: widget.profileService,
            onCompleted: (_) => _reload(),
            onSignOut: _signOut,
          );
        }

        return KotaShell(
          profile: profile,
          profileService: widget.profileService,
          onSignOut: _signOut,
        );
      },
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({
    required this.message,
    required this.onRetry,
    required this.onSignOut,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: Colors.grey.shade600),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
              TextButton(onPressed: onSignOut, child: const Text('Sign out')),
            ],
          ),
        ),
      ),
    );
  }
}
