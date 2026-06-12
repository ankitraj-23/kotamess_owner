import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-owner preference controlling which items the Home "Recent
/// activity" feed shows.
///
/// Clearing only records a timestamp; it NEVER deletes meal requests, imported
/// messages or ledger entries. The Home feed simply hides activity items whose
/// timestamp is at/older than this value. The key is scoped by owner id so two
/// owners signing in on the same device don't share the setting.
class RecentActivityPrefs {
  static const _keyPrefix = 'recent_activity_cleared_at_';

  String _key(String ownerId) => '$_keyPrefix$ownerId';

  /// The instant the owner last cleared their Home activity feed, or null if
  /// they never have.
  Future<DateTime?> clearedAt(String ownerId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(ownerId));
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  /// Records "now" as the cutoff so older activity is hidden from Home.
  Future<void> clearNow(String ownerId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(ownerId),
      DateTime.now().toUtc().toIso8601String(),
    );
  }
}
