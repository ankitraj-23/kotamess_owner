import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import 'owner_profile.dart';

/// Reads and writes the signed-in owner's row in `owner_profiles`.
///
/// RLS guarantees a user can only ever touch the row whose `id` equals their
/// auth uid, so every query here is implicitly scoped to the current user.
class OwnerProfileService {
  OwnerProfileService([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  static const _table = 'owner_profiles';

  /// Returns the current owner's profile, or null if no row exists yet.
  Future<OwnerProfile?> loadCurrent() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    final row =
        await _client.from(_table).select().eq('id', user.id).maybeSingle();

    if (row == null) return null;
    return OwnerProfile.fromJson(row);
  }

  /// Alias used by screens that just want the current profile.
  Future<OwnerProfile?> fetchProfile() => loadCurrent();

  /// Persists the editable Settings fields for the current owner and returns
  /// the refreshed row. RLS keeps the update scoped to the signed-in user.
  Future<OwnerProfile> updateProfile(OwnerProfile profile) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('Cannot update a profile while signed out.');
    }

    final row = await _client
        .from(_table)
        .update(profile.toUpdate())
        .eq('id', user.id)
        .select()
        .single();

    return OwnerProfile.fromJson(row);
  }

  /// Idempotently writes the current user's profile row.
  ///
  /// Upsert on the primary key (`id` == auth uid) guarantees there can only
  /// ever be one row per owner, so this is safe to call from multiple paths
  /// (metadata bootstrap, complete-profile screen, retries) without creating
  /// duplicates.
  Future<OwnerProfile> upsertProfile({
    required String ownerName,
    required String messName,
    String phone = '',
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('Cannot save a profile while signed out.');
    }

    final profile = OwnerProfile(
      id: user.id,
      email: user.email ?? '',
      ownerName: ownerName.trim(),
      messName: messName.trim(),
      phone: phone.trim(),
      retentionDays: 90,
    );

    final row = await _client
        .from(_table)
        .upsert(profile.toInsert(), onConflict: 'id')
        .select()
        .single();

    return OwnerProfile.fromJson(row);
  }

  /// Resolves the owner profile for the signed-in user on app entry:
  ///   * returns the existing row if there is one;
  ///   * otherwise creates it from the owner/mess name stored in user metadata
  ///     at sign up;
  ///   * returns null only when no row exists AND metadata is incomplete, which
  ///     is the single case where [CompleteProfileScreen] should appear.
  Future<OwnerProfile?> resolveOnEntry() async {
    final existing = await loadCurrent();
    if (existing != null) return existing;

    final meta = _client.auth.currentUser?.userMetadata ?? const {};
    final ownerName = (meta[AuthService.ownerNameKey] as String?)?.trim() ?? '';
    final messName = (meta[AuthService.messNameKey] as String?)?.trim() ?? '';

    if (ownerName.isEmpty || messName.isEmpty) return null;

    return upsertProfile(ownerName: ownerName, messName: messName);
  }
}
