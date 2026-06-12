import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase/supabase_config.dart';

/// What a sign-up attempt actually resulted in. Supabase deliberately
/// obscures whether an email already exists (to prevent enumeration), so we
/// infer the outcome from the response shape rather than a clear error.
enum SignUpOutcome {
  /// Email confirmation is OFF — a session was returned and the user is in.
  signedIn,

  /// New (or existing-but-unconfirmed) account — a confirmation email was sent
  /// and the user must verify before signing in.
  needsVerification,

  /// An account already exists for this email (and is confirmed). Supabase
  /// returns a user with an empty `identities` list in this case, or throws a
  /// "user already registered" style error.
  alreadyExists,

  /// Response we did not recognise — surface a generic error.
  unknown,
}

/// Thin wrapper around Supabase Auth so the rest of the app never touches the
/// Supabase client directly for sign in / sign up / sign out.
///
/// Session persistence is handled automatically by `supabase_flutter`: the
/// session is stored on device and restored on the next launch, and refreshed
/// in the background. We just expose the current session and a change stream.
class AuthService {
  AuthService([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  /// Emits on every auth change (sign in, sign out, token refresh, restore).
  Stream<AuthState> get onAuthStateChange => _auth.onAuthStateChange;

  Session? get currentSession => _auth.currentSession;

  User? get currentUser => _auth.currentUser;

  bool get isSignedIn => currentSession != null;

  /// Owner/mess names entered at sign up are stored in user metadata so the
  /// owner profile can be created automatically on first authenticated launch,
  /// without asking for them a second time.
  static const ownerNameKey = 'owner_name';
  static const messNameKey = 'mess_name';

  /// Creates a new account, stashing owner + mess name in user metadata, and
  /// classifies the result. Confirmation links redirect to
  /// [SupabaseConfig.emailRedirectUrl].
  ///
  /// We do NOT create any profile row here — that only happens once a real
  /// authenticated session exists (see [OwnerProfileService.resolveOnEntry]).
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String ownerName,
    required String messName,
  }) async {
    try {
      final res = await _auth.signUp(
        email: email.trim(),
        password: password,
        emailRedirectTo: SupabaseConfig.emailRedirectUrl,
        data: {
          ownerNameKey: ownerName.trim(),
          messNameKey: messName.trim(),
        },
      );

      if (res.session != null) return SignUpOutcome.signedIn;

      final user = res.user;
      if (user == null) return SignUpOutcome.unknown;

      // Empty identities => Supabase recognised the email as already taken and
      // returned an obfuscated user. Treat as existing account, not a new one.
      final identities = user.identities;
      if (identities != null && identities.isEmpty) {
        return SignUpOutcome.alreadyExists;
      }

      return SignUpOutcome.needsVerification;
    } on AuthException catch (e) {
      if (isAlreadyRegistered(e)) return SignUpOutcome.alreadyExists;
      rethrow;
    }
  }

  /// Recognises the various "email already registered" errors Supabase can
  /// throw when enumeration protection is off.
  bool isAlreadyRegistered(AuthException e) {
    final code = e.code?.toLowerCase() ?? '';
    if (code == 'user_already_exists' || code == 'email_exists') return true;
    final msg = e.message.toLowerCase();
    return msg.contains('already registered') ||
        msg.contains('already exists') ||
        msg.contains('already been registered');
  }

  bool isEmailNotConfirmed(AuthException e) {
    final code = e.code?.toLowerCase() ?? '';
    if (code == 'email_not_confirmed') return true;
    return e.message.toLowerCase().contains('not confirmed');
  }

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) {
    return _auth.signInWithPassword(email: email.trim(), password: password);
  }

  /// Re-sends the sign-up confirmation email, pointing back at the configured
  /// redirect URL. Supabase rate-limits this, so callers should surface any
  /// [AuthException] (e.g. "try again later").
  Future<void> resendConfirmationEmail(String email) {
    return _auth.resend(
      type: OtpType.signup,
      email: email.trim(),
      emailRedirectTo: SupabaseConfig.emailRedirectUrl,
    );
  }

  /// Sends a password-reset email using the same redirect URL.
  Future<void> sendPasswordReset(String email) {
    return _auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: SupabaseConfig.emailRedirectUrl,
    );
  }

  Future<void> signOut() => _auth.signOut();
}
