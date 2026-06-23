import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Reads Supabase credentials from the bundled `.env` file, with a
/// `--dart-define` fallback so CI / release builds can inject values without
/// shipping an `.env` asset.
///
/// Never put the `service_role` key here. Only the public anon / publishable
/// key belongs in a client app.
class SupabaseConfig {
  const SupabaseConfig._();

  static const String _urlDefine = String.fromEnvironment('SUPABASE_URL');
  // Accept either name from --dart-define; the publishable key is the new name
  // for the anon key.
  static const String _publishableKeyDefine =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const String _anonKeyDefine =
      String.fromEnvironment('SUPABASE_ANON_KEY');
  static const String _emailRedirectDefine =
      String.fromEnvironment('SUPABASE_EMAIL_REDIRECT_URL');

  /// Reads a key from `.env`, but only once dotenv has been initialised.
  /// Returns null otherwise so callers never trigger flutter_dotenv's
  /// `NotInitializedError` (which crashes startup when the `.env` asset is
  /// missing or failed to load).
  static String? _env(String key) =>
      dotenv.isInitialized ? dotenv.maybeGet(key) : null;

  static String get url {
    final fromEnv = _env('SUPABASE_URL');
    return (fromEnv != null && fromEnv.isNotEmpty) ? fromEnv : _urlDefine;
  }

  static String get anonKey {
    // Prefer the publishable-key name, fall back to the legacy anon-key name so
    // existing `.env` files keep working.
    final fromEnv = _env('SUPABASE_PUBLISHABLE_KEY') ?? _env('SUPABASE_ANON_KEY');
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    return _publishableKeyDefine.isNotEmpty ? _publishableKeyDefine : _anonKeyDefine;
  }

  /// HTTPS page the Supabase confirmation / reset links redirect to after the
  /// browser verifies the token. Must also be listed under Supabase
  /// Authentication -> URL Configuration -> Redirect URLs, or the link errors.
  ///
  /// Returns null when unset, so the SDK falls back to the project Site URL.
  static String? get emailRedirectUrl {
    final fromEnv = _env('SUPABASE_EMAIL_REDIRECT_URL');
    final value =
        (fromEnv != null && fromEnv.isNotEmpty) ? fromEnv : _emailRedirectDefine;
    return value.isEmpty ? null : value;
  }

  /// True once both values are present, regardless of source.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// Loads the `.env` asset before anything reads credentials. Safe to call
  /// even when the file is missing or not declared as an asset: on failure it
  /// initialises dotenv with an empty map so later `_env(...)` reads return null
  /// (and we fall back to `--dart-define`) instead of throwing
  /// NotInitializedError at startup.
  static Future<void> loadEnv() async {
    try {
      await dotenv.load(fileName: '.env');
    } catch (_) {
      // No usable .env (missing file / not bundled): mark dotenv initialised
      // with an empty environment so the getters degrade gracefully and the
      // app shows the "Backend not configured" screen instead of crashing.
      if (!dotenv.isInitialized) {
        dotenv.testLoad(fileInput: '');
      }
    }
  }
}
