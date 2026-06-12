import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Reads Supabase credentials from the bundled `.env` file, with a
/// `--dart-define` fallback so CI / release builds can inject values without
/// shipping an `.env` asset.
///
/// Never put the `service_role` key here. Only the public anon key belongs in
/// a client app.
class SupabaseConfig {
  const SupabaseConfig._();

  static const String _urlDefine = String.fromEnvironment('SUPABASE_URL');
  static const String _anonKeyDefine =
      String.fromEnvironment('SUPABASE_ANON_KEY');
  static const String _emailRedirectDefine =
      String.fromEnvironment('SUPABASE_EMAIL_REDIRECT_URL');

  static String get url {
    final fromEnv = dotenv.maybeGet('SUPABASE_URL');
    return (fromEnv != null && fromEnv.isNotEmpty) ? fromEnv : _urlDefine;
  }

  static String get anonKey {
    final fromEnv = dotenv.maybeGet('SUPABASE_ANON_KEY');
    return (fromEnv != null && fromEnv.isNotEmpty) ? fromEnv : _anonKeyDefine;
  }

  /// HTTPS page the Supabase confirmation / reset links redirect to after the
  /// browser verifies the token. Must also be listed under Supabase
  /// Authentication -> URL Configuration -> Redirect URLs, or the link errors.
  ///
  /// Returns null when unset, so the SDK falls back to the project Site URL.
  static String? get emailRedirectUrl {
    final fromEnv = dotenv.maybeGet('SUPABASE_EMAIL_REDIRECT_URL');
    final value =
        (fromEnv != null && fromEnv.isNotEmpty) ? fromEnv : _emailRedirectDefine;
    return value.isEmpty ? null : value;
  }

  /// True once both values are present, regardless of source.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// Loads the `.env` asset. Safe to call even when the file is missing or
  /// not declared as an asset (returns without throwing).
  static Future<void> loadEnv() async {
    try {
      await dotenv.load(fileName: '.env');
    } catch (_) {
      // No .env asset bundled — fall back to --dart-define values.
    }
  }
}
