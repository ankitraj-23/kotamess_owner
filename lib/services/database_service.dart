import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/daily_adjustment.dart';
import '../models/daily_summary.dart';
import '../models/dashboard.dart';
import '../models/extraction_result.dart';
import '../models/ledger_entry.dart';
import '../models/meal_request.dart';
import '../models/student.dart';
import 'money_utils.dart';
import 'name_utils.dart';

/// All Supabase reads/writes for the import → requests workflow.
///
/// Every write includes `owner_id = currentOwnerId`, and every read filters by
/// it too. RLS enforces isolation server-side; we still set owner_id correctly
/// so inserts pass the WITH CHECK policy.
class DatabaseService {
  DatabaseService([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  String getCurrentOwnerId() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('No authenticated session.');
    }
    return user.id;
  }

  // --- Imported messages --------------------------------------------------

  /// Saves the raw chat for traceability and returns its id.
  Future<String> saveImportedMessage({
    required String rawText,
    required String source, // 'paste' | 'file'
  }) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('imported_messages')
        .insert({
          'owner_id': ownerId,
          'source': source == 'file' ? 'whatsapp_file' : 'paste',
          'raw_text': rawText,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  // --- Meal requests ------------------------------------------------------

  /// Saves extracted requests as `pending`, linking each to a student
  /// (existing or newly created) for this owner. Returns the inserted rows.
  Future<List<MealRequest>> saveExtractedMealRequests(
    List<ExtractedRequest> items, {
    required String source,
    String? importedMessageId,
  }) async {
    if (items.isEmpty) return [];
    final ownerId = getCurrentOwnerId();
    final studentIds = await _resolveStudentIds(
      items.map((e) => e.studentName).toList(),
      ownerId,
    );

    final rows = items.map((it) {
      final key = _nameKey(it.studentName);
      return <String, dynamic>{
        'owner_id': ownerId,
        'student_id': studentIds[key],
        'student_name': it.studentName,
        'original_message': it.originalMessage,
        'request_type': it.requestType,
        'meal_type': it.mealType,
        'request_date': it.requestDate,
        'date_label': it.dateLabel,
        'status': 'pending',
        'confidence': it.confidence,
        'reason': it.reason,
        'source': source,
        if (importedMessageId != null) 'imported_message_id': importedMessageId,
      };
    }).toList();

    final inserted = await _client.from('meal_requests').insert(rows).select();
    return inserted
        .map((e) => MealRequest.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<MealRequest>> fetchMealRequests({
    String? status, // 'pending'|'approved'|'rejected'|null/'all'
    String? search,
  }) async {
    final ownerId = getCurrentOwnerId();
    var query = _client.from('meal_requests').select().eq('owner_id', ownerId);
    if (status != null && status != 'all') {
      query = query.eq('status', status);
    }
    if (search != null && search.trim().isNotEmpty) {
      query = query.ilike('student_name', '%${search.trim()}%');
    }
    final rows = await query.order('created_at', ascending: false);
    return rows
        .map((e) => MealRequest.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Approves a request and, for payment/dues requests, auto-creates a single
  /// linked ledger entry. Returns true when a ledger entry was created (so the
  /// UI can show "Approved and added to Ledger").
  Future<bool> approveMealRequest(String id) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('meal_requests')
        .update({'status': 'approved'})
        .eq('id', id)
        .eq('owner_id', ownerId)
        .select()
        .maybeSingle();
    if (row == null) return false;
    final req = MealRequest.fromJson(Map<String, dynamic>.from(row));
    return _maybeCreateLedgerForApproved(req);
  }

  Future<void> rejectMealRequest(String id) => _setStatus(id, 'rejected');

  Future<int> approveMany(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final ownerId = getCurrentOwnerId();
    final updated = await _client
        .from('meal_requests')
        .update({'status': 'approved'})
        .inFilter('id', ids)
        .eq('owner_id', ownerId)
        .select();
    // Auto-create ledger entries for any approved payment/dues requests.
    for (final row in updated) {
      final req = MealRequest.fromJson(Map<String, dynamic>.from(row));
      await _maybeCreateLedgerForApproved(req);
    }
    return updated.length;
  }

  /// meal_request ids (for this owner) that already have a linked ledger entry,
  /// so the Requests screen can show a "Ledger linked" badge.
  Future<Set<String>> fetchRequestIdsWithLedger() async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('ledger_entries')
        .select('meal_request_id')
        .eq('owner_id', ownerId)
        .not('meal_request_id', 'is', null);
    return rows
        .map((e) => e['meal_request_id'] as String?)
        .whereType<String>()
        .toSet();
  }

  /// Creates an automatic ledger entry for an approved payment_note / dues_query
  /// request, exactly once. Safe to call repeatedly: a pre-check plus the
  /// (owner_id, meal_request_id) unique index prevent duplicates on re-approval.
  /// Other request types never touch the ledger. Returns true when created.
  Future<bool> _maybeCreateLedgerForApproved(MealRequest req) async {
    if (req.requestType != 'payment_note' && req.requestType != 'dues_query') {
      return false;
    }
    final ownerId = getCurrentOwnerId();

    final existing = await _client
        .from('ledger_entries')
        .select('id')
        .eq('owner_id', ownerId)
        .eq('meal_request_id', req.id)
        .maybeSingle();
    if (existing != null) return false;

    String entryType;
    int amount;
    String note;
    final msg = req.originalMessage.trim();
    if (req.requestType == 'payment_note') {
      amount = MoneyUtils.parseAmount(req.originalMessage);
      entryType = amount > 0 ? 'payment' : 'note';
      note = msg.isEmpty
          ? 'Payment noted from approved WhatsApp request.'
          : '$msg — from approved WhatsApp request';
    } else {
      entryType = 'note';
      amount = 0;
      note = msg.isEmpty
          ? 'Student asked about dues (from approved request).'
          : '$msg — student asked about dues (from approved request)';
    }

    // Prefer the already-linked canonical student; otherwise resolve by name.
    var studentId = req.studentId;
    final name = req.studentName.trim();
    if (studentId == null && name.isNotEmpty) {
      final ids = await _resolveStudentIds([name], ownerId);
      studentId = ids[_nameKey(name)];
    }

    try {
      await _client.from('ledger_entries').insert({
        'owner_id': ownerId,
        'student_id': studentId,
        'student_name': name,
        'meal_request_id': req.id,
        'entry_type': entryType,
        'amount': amount,
        'note': note,
        'entry_date': _dateStr(DateTime.now()),
      });
      return true;
    } on PostgrestException catch (e) {
      // 23505 = unique_violation: a concurrent approval already linked one.
      if (e.code == '23505') return false;
      rethrow;
    }
  }

  Future<MealRequest> updateMealRequest(MealRequest request) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('meal_requests')
        .update(request.toEditableUpdate())
        .eq('id', request.id)
        .eq('owner_id', ownerId)
        .select()
        .single();
    return MealRequest.fromJson(Map<String, dynamic>.from(row));
  }

  Future<void> deleteMealRequest(String id) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('meal_requests')
        .delete()
        .eq('id', id)
        .eq('owner_id', ownerId);
  }

  Future<void> _setStatus(String id, String status) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('meal_requests')
        .update({'status': status})
        .eq('id', id)
        .eq('owner_id', ownerId);
  }

  // --- Students -----------------------------------------------------------

  /// Maps each distinct, real student name to a student id for this owner,
  /// creating rows for names that don't exist yet. Names like "Unknown" or
  /// blanks map to null (left unlinked).
  Future<Map<String, String?>> _resolveStudentIds(
    List<String> names,
    String ownerId,
  ) async {
    final distinct = <String, String>{}; // key -> display name
    for (final n in names) {
      final key = _nameKey(n);
      if (key.isEmpty || key == 'unknown') continue;
      distinct.putIfAbsent(key, () => n.trim());
    }
    final result = <String, String?>{};
    if (distinct.isEmpty) return result;

    final existing = await _client
        .from('students')
        .select('id, name')
        .eq('owner_id', ownerId);
    for (final s in existing) {
      result[_nameKey(s['name'] as String? ?? '')] = s['id'] as String?;
    }

    // Known aliases let alternate spellings ("Amit" -> "Amit Sharma") resolve
    // to the existing student instead of creating a duplicate.
    final aliases = await _client
        .from('student_aliases')
        .select('student_id, normalized_alias')
        .eq('owner_id', ownerId);
    for (final a in aliases) {
      final key = a['normalized_alias'] as String? ?? '';
      if (key.isEmpty) continue;
      result.putIfAbsent(key, () => a['student_id'] as String?);
    }

    final toCreate =
        distinct.entries.where((e) => !result.containsKey(e.key)).toList();
    if (toCreate.isNotEmpty) {
      final inserted = await _client
          .from('students')
          .insert(toCreate
              .map((e) => {'owner_id': ownerId, 'name': e.value})
              .toList())
          .select('id, name');
      for (final s in inserted) {
        result[_nameKey(s['name'] as String? ?? '')] = s['id'] as String?;
      }
    }
    return result;
  }

  /// Normalized identity key for a name (lowercased, honorifics stripped) so
  /// "Amit", "amit bhai" and "Amit  " collapse to the same student.
  String _nameKey(String name) => NameUtils.normalize(name);

  static String _dateStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// All students for this owner, ordered by name. Used by link/merge UIs.
  Future<List<Student>> fetchStudents() async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('students')
        .select('id, name')
        .eq('owner_id', ownerId)
        .order('name');
    return rows
        .map((e) => Student.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Creates a canonical student (or returns the existing one if the normalized
  /// name already exists for this owner).
  Future<Student> createStudent(String name) async {
    final ownerId = getCurrentOwnerId();
    final ids = await _resolveStudentIds([name], ownerId);
    final id = ids[_nameKey(name)];
    if (id != null) {
      final existing = await fetchStudents();
      final match = existing.where((s) => s.id == id).toList();
      if (match.isNotEmpty) return match.first;
    }
    final row = await _client
        .from('students')
        .insert({'owner_id': ownerId, 'name': name.trim()})
        .select('id, name')
        .single();
    return Student.fromJson(Map<String, dynamic>.from(row));
  }

  /// Records [alias] as an alternate name for [studentId] so future imports /
  /// lookups of that spelling resolve to this student. Idempotent: re-pointing
  /// an alias updates its target rather than creating a duplicate. No-op for
  /// aliases that normalize to empty or already equal the student's own name.
  Future<void> addAlias({
    required String studentId,
    required String alias,
  }) async {
    final ownerId = getCurrentOwnerId();
    final normalized = NameUtils.normalize(alias);
    if (normalized.isEmpty) return;
    await _client.from('student_aliases').upsert({
      'owner_id': ownerId,
      'student_id': studentId,
      'alias': alias.trim(),
      'normalized_alias': normalized,
    }, onConflict: 'owner_id,normalized_alias');
  }

  /// Suggests existing students for a (possibly partial) [name]: exact and
  /// alias matches first, then conservative token-overlap "possible" matches
  /// ("Amit" ⊂ "Amit Sharma"). Never mutates data — the caller decides.
  Future<List<StudentCandidate>> findStudentMatches(String name) async {
    final ownerId = getCurrentOwnerId();
    final key = NameUtils.normalize(name);
    if (key.isEmpty) return [];

    final students = await fetchStudents();
    final byId = {for (final s in students) s.id: s};

    final aliasRows = await _client
        .from('student_aliases')
        .select('student_id, alias, normalized_alias')
        .eq('owner_id', ownerId);

    final out = <String, StudentCandidate>{}; // student_id -> best candidate

    void consider(StudentCandidate c) {
      final existing = out[c.student.id];
      // Keep the strongest match kind per student (exact < alias < partial).
      if (existing == null || c.kind.index < existing.kind.index) {
        out[c.student.id] = c;
      }
    }

    for (final s in students) {
      if (NameUtils.normalize(s.name) == key) {
        consider(StudentCandidate(student: s, kind: StudentMatchKind.exact));
      }
    }
    for (final a in aliasRows) {
      if ((a['normalized_alias'] as String? ?? '') == key) {
        final s = byId[a['student_id'] as String?];
        if (s != null) {
          consider(StudentCandidate(
            student: s,
            kind: StudentMatchKind.alias,
            matchedAlias: a['alias'] as String?,
          ));
        }
      }
    }
    for (final s in students) {
      if (NameUtils.isPossibleMatch(s.name, name)) {
        consider(StudentCandidate(student: s, kind: StudentMatchKind.partial));
      }
    }

    final list = out.values.toList()
      ..sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return list;
  }

  /// Links a meal request to a canonical student and stores the request's old
  /// extracted name as an alias, so future imports of that name auto-link.
  Future<void> linkRequestToStudent({
    required String requestId,
    required String studentId,
    required String canonicalName,
    String? aliasToSave,
  }) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('meal_requests')
        .update({'student_id': studentId, 'student_name': canonicalName.trim()})
        .eq('id', requestId)
        .eq('owner_id', ownerId);
    if (aliasToSave != null && aliasToSave.trim().isNotEmpty) {
      await addAlias(studentId: studentId, alias: aliasToSave);
    }
  }

  /// Merges [sourceId] into [targetId]: moves this owner's meal requests and
  /// ledger entries to the target, records the source's name as an alias of the
  /// target, then deletes the source student. Owner-scoped throughout.
  Future<void> mergeStudents({
    required String sourceId,
    required String targetId,
  }) async {
    if (sourceId == targetId) return;
    final ownerId = getCurrentOwnerId();

    final students = await fetchStudents();
    final source = students.where((s) => s.id == sourceId).toList();
    final target = students.where((s) => s.id == targetId).toList();
    if (source.isEmpty || target.isEmpty) {
      throw StateError('Both students must exist to merge.');
    }
    final targetName = target.first.name;

    await _client
        .from('meal_requests')
        .update({'student_id': targetId, 'student_name': targetName})
        .eq('owner_id', ownerId)
        .eq('student_id', sourceId);

    await _client
        .from('ledger_entries')
        .update({'student_id': targetId, 'student_name': targetName})
        .eq('owner_id', ownerId)
        .eq('student_id', sourceId);

    // Re-home the source's aliases onto the target, then add the source's own
    // name as an alias. We delete-then-upsert (rather than bulk update) so a
    // shared alias can't trip the (owner_id, normalized_alias) unique index.
    final sourceAliases = await _client
        .from('student_aliases')
        .select('alias')
        .eq('owner_id', ownerId)
        .eq('student_id', sourceId);
    await _client
        .from('student_aliases')
        .delete()
        .eq('owner_id', ownerId)
        .eq('student_id', sourceId);
    for (final a in sourceAliases) {
      await addAlias(studentId: targetId, alias: a['alias'] as String? ?? '');
    }
    await addAlias(studentId: targetId, alias: source.first.name);

    await _client
        .from('students')
        .delete()
        .eq('id', sourceId)
        .eq('owner_id', ownerId);
  }

  // --- Dashboard ----------------------------------------------------------

  /// Aggregates the Home dashboard: today's final counts, pending/approved
  /// tallies, import stats, and a merged recent-activity feed.
  Future<DashboardSummary> fetchDashboardSummary({
    required int baseLunch,
    required int baseDinner,
  }) async {
    final ownerId = getCurrentOwnerId();
    final today = _dateStr(DateTime.now());

    final requestRows = await _client
        .from('meal_requests')
        .select()
        .eq('owner_id', ownerId)
        .order('created_at', ascending: false);
    final requests = requestRows
        .map((e) => MealRequest.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    final approved = requests.where((r) => r.status == 'approved').toList();
    final pendingCount = requests.where((r) => r.status == 'pending').length;

    final todayDate = DateTime.parse(today);
    final approvedTodayCount = approved.where((r) {
      final eff = DailySummary.effectiveDate(r);
      return eff != null && eff == todayDate;
    }).length;

    final adjustments = await fetchDailyAdjustments(today);
    final summary = DailySummary.compute(
      date: today,
      baseLunch: baseLunch,
      baseDinner: baseDinner,
      approvedRequests: approved,
      adjustments: adjustments,
    );

    final importRows = await _client
        .from('imported_messages')
        .select('id, created_at')
        .eq('owner_id', ownerId)
        .order('created_at', ascending: false);
    final importedCount = importRows.length;
    final latestImportAt = importRows.isEmpty
        ? null
        : DateTime.tryParse(importRows.first['created_at'] as String? ?? '');

    final ledgerRows = await _client
        .from('ledger_entries')
        .select()
        .eq('owner_id', ownerId)
        .order('created_at', ascending: false)
        .limit(5);
    final ledger = ledgerRows
        .map((e) => LedgerEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    final activity = _buildActivity(requests, ledger);

    return DashboardSummary(
      finalLunch: summary.finalLunch,
      finalDinner: summary.finalDinner,
      pendingCount: pendingCount,
      approvedTodayCount: approvedTodayCount,
      importedCount: importedCount,
      latestImportAt: latestImportAt,
      recentActivity: activity,
    );
  }

  List<ActivityItem> _buildActivity(
    List<MealRequest> requests,
    List<LedgerEntry> ledger,
  ) {
    final items = <ActivityItem>[];
    for (final r in requests.take(8)) {
      items.add(ActivityItem(
        kind: 'request_${r.status}',
        title: r.studentName,
        subtitle: '${r.requestTypeLabel} · ${r.statusLabel}',
        timestamp: r.createdAt,
      ));
    }
    for (final l in ledger.take(5)) {
      final amount = l.amount == 0 ? '' : ' · ₹${l.amount}';
      items.add(ActivityItem(
        kind: 'ledger',
        title: l.studentName.isEmpty ? 'Ledger entry' : l.studentName,
        subtitle: '${l.entryTypeLabel}$amount',
        timestamp: l.createdAt,
      ));
    }
    items.sort((a, b) {
      final at = a.timestamp ?? DateTime(2000);
      final bt = b.timestamp ?? DateTime(2000);
      return bt.compareTo(at);
    });
    return items.take(10).toList();
  }

  // --- Daily count --------------------------------------------------------

  /// Builds the count breakdown for [date] ('YYYY-MM-DD') from approved
  /// requests + manual adjustments. Base counts come from the owner profile.
  Future<DailySummary> fetchDailySummary({
    required String date,
    required int baseLunch,
    required int baseDinner,
  }) async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('meal_requests')
        .select()
        .eq('owner_id', ownerId)
        .eq('status', 'approved');
    final approved = rows
        .map((e) => MealRequest.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final adjustments = await fetchDailyAdjustments(date);

    return DailySummary.compute(
      date: date,
      baseLunch: baseLunch,
      baseDinner: baseDinner,
      approvedRequests: approved,
      adjustments: adjustments,
    );
  }

  Future<List<DailyAdjustment>> fetchDailyAdjustments(String date) async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('daily_adjustments')
        .select()
        .eq('owner_id', ownerId)
        .eq('adjustment_date', date)
        .order('created_at', ascending: false);
    return rows
        .map((e) => DailyAdjustment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Stores a manual adjustment as up to two rows (one per non-zero meal delta).
  Future<void> createDailyAdjustment({
    required String date,
    required int lunchDelta,
    required int dinnerDelta,
    required String note,
  }) async {
    final ownerId = getCurrentOwnerId();
    final rows = <Map<String, dynamic>>[];
    if (lunchDelta != 0) {
      rows.add({
        'owner_id': ownerId,
        'adjustment_date': date,
        'meal': 'lunch',
        'delta': lunchDelta,
        'reason': note.trim(),
      });
    }
    if (dinnerDelta != 0) {
      rows.add({
        'owner_id': ownerId,
        'adjustment_date': date,
        'meal': 'dinner',
        'delta': dinnerDelta,
        'reason': note.trim(),
      });
    }
    if (rows.isEmpty) return;
    await _client.from('daily_adjustments').insert(rows);
  }

  Future<void> deleteDailyAdjustment(String id) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('daily_adjustments')
        .delete()
        .eq('id', id)
        .eq('owner_id', ownerId);
  }

  // --- Ledger -------------------------------------------------------------

  Future<List<LedgerEntry>> fetchLedgerEntries({
    String? search,
    String? type, // 'payment'|'due'|'adjustment'|'note'|null/'all'
  }) async {
    final ownerId = getCurrentOwnerId();
    var query = _client.from('ledger_entries').select().eq('owner_id', ownerId);
    if (type != null && type != 'all') {
      query = query.eq('entry_type', type);
    }
    if (search != null && search.trim().isNotEmpty) {
      query = query.ilike('student_name', '%${search.trim()}%');
    }
    final rows = await query.order('created_at', ascending: false);
    return rows
        .map((e) => LedgerEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<LedgerEntry> createLedgerEntry({
    required String studentName,
    required String entryType,
    required int amount,
    required String note,
    String? entryDate,
    String? studentId,
  }) async {
    final ownerId = getCurrentOwnerId();
    final name = studentName.trim();
    // When the owner picked an existing student suggestion we trust that id;
    // otherwise resolve by name (which also consults aliases).
    final resolvedId = studentId ??
        (await _resolveStudentIds([name], ownerId))[_nameKey(name)];
    final row = await _client
        .from('ledger_entries')
        .insert({
          'owner_id': ownerId,
          'student_id': resolvedId,
          'student_name': name,
          'entry_type': entryType,
          'amount': amount,
          'note': note.trim(),
          'entry_date': entryDate ?? _dateStr(DateTime.now()),
        })
        .select()
        .single();
    return LedgerEntry.fromJson(Map<String, dynamic>.from(row));
  }

  Future<LedgerEntry> updateLedgerEntry(LedgerEntry entry) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('ledger_entries')
        .update({
          'student_name': entry.studentName.trim(),
          'entry_type': entry.entryType,
          'amount': entry.amount,
          'note': entry.note.trim(),
        })
        .eq('id', entry.id)
        .eq('owner_id', ownerId)
        .select()
        .single();
    return LedgerEntry.fromJson(Map<String, dynamic>.from(row));
  }

  Future<void> deleteLedgerEntry(String id) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('ledger_entries')
        .delete()
        .eq('id', id)
        .eq('owner_id', ownerId);
  }

  // --- Retention / cleanup ------------------------------------------------

  /// Deletes this owner's imported_messages older than [retentionDays] and
  /// returns how many were removed. Does NOT touch meal_requests, students,
  /// ledger entries, the owner profile or the auth account.
  Future<int> cleanupOldImportedMessages(int retentionDays) async {
    final ownerId = getCurrentOwnerId();
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    final deleted = await _client
        .from('imported_messages')
        .delete()
        .eq('owner_id', ownerId)
        .lt('created_at', cutoff.toIso8601String())
        .select('id');
    return deleted.length;
  }
}
