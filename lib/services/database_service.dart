import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/audit_log.dart';
import '../models/chat_import.dart';
import '../models/chat_message.dart';
import '../models/daily_adjustment.dart';
import '../models/daily_summary.dart';
import '../models/dashboard.dart';
import '../models/kitchen_summary.dart';
import '../models/ledger_entry.dart';
import '../models/meal_plan.dart';
import '../models/meal_request.dart';
import '../models/monthly_bill.dart';
import '../models/payment.dart';
import '../models/student.dart';
import 'money_utils.dart';
import 'name_utils.dart';

/// Thrown when an unresolved-sender request is asked to transition into an
/// approved/confirmed/completed state. The message is owner-facing and safe to
/// show directly in a SnackBar.
class UnresolvedSenderException implements Exception {
  const UnresolvedSenderException(
      [this.message = 'Resolve the student before approving this request.']);
  final String message;
  @override
  String toString() => message;
}

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

  // --- Audit log ----------------------------------------------------------

  /// Appends an entry to `audit_logs` for an important action. Best-effort:
  /// a failed audit write never blocks (or rolls back) the primary action.
  Future<void> _writeAudit({
    required String entityType,
    String? entityId,
    required String action,
    Map<String, dynamic>? oldData,
    Map<String, dynamic>? newData,
  }) async {
    try {
      final ownerId = getCurrentOwnerId();
      await _client.from('audit_logs').insert({
        'owner_id': ownerId,
        'actor_id': ownerId,
        'entity_type': entityType,
        if (entityId != null) 'entity_id': entityId,
        'action': action,
        if (oldData != null) 'old_data': oldData,
        if (newData != null) 'new_data': newData,
      });
    } catch (_) {
      // Audit logging is best-effort; swallow so the user action still succeeds.
    }
  }

  /// Recent audit entries, newest first. Optionally scoped to one entity (e.g.
  /// a customer's change history).
  Future<List<AuditLog>> fetchAuditLogs({
    String? entityType,
    String? entityId,
    int limit = 20,
  }) async {
    final ownerId = getCurrentOwnerId();
    var query = _client.from('audit_logs').select().eq('owner_id', ownerId);
    if (entityType != null) query = query.eq('entity_type', entityType);
    if (entityId != null) query = query.eq('entity_id', entityId);
    final rows =
        await query.order('created_at', ascending: false).limit(limit);
    return rows
        .map((e) => AuditLog.fromJson(Map<String, dynamic>.from(e)))
        .toList();
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

  // --- Chat import history (read-only) ------------------------------------
  //
  // The `extract-requests` Edge Function writes chat_imports / chat_messages
  // server-side; the app only reads them, owner-scoped, for Import History.

  /// Past import runs for this owner, newest first.
  Future<List<ChatImport>> fetchChatImports({int limit = 50}) async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('chat_imports')
        .select()
        .eq('owner_id', ownerId)
        .order('created_at', ascending: false)
        .limit(limit);
    return rows
        .map((e) => ChatImport.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Parsed messages for one import run, newest first (capped for the UI).
  Future<List<ChatMessage>> fetchChatMessages(
    String importId, {
    int limit = 50,
  }) async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('chat_messages')
        .select()
        .eq('owner_id', ownerId)
        .eq('import_id', importId)
        .order('message_timestamp', ascending: false, nullsFirst: false)
        .order('created_at', ascending: false)
        .limit(limit);
    return rows
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Extracted requests linked to one import run, newest first.
  Future<List<MealRequest>> fetchRequestsForImport(String importId) async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('meal_requests')
        .select()
        .eq('owner_id', ownerId)
        .eq('import_id', importId)
        .order('created_at', ascending: false);
    return rows
        .map((e) => MealRequest.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  // --- Meal requests ------------------------------------------------------
  //
  // Extracted requests are saved server-side by the `extract-requests` Edge
  // Function (as pending `meal_requests`); the app only reads/updates them here.

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

  /// Approves ("confirms") a request and, for payment/dues requests,
  /// auto-creates a single linked ledger entry. Returns true when a ledger
  /// entry was created (so the UI can show "Confirmed and added to Ledger").
  Future<bool> approveMealRequest(String id) async {
    final req = await _updateRequestStatus(id, 'approved', 'confirm');
    if (req == null) return false;
    return _maybeCreateLedgerForApproved(req);
  }

  Future<void> rejectMealRequest(String id) =>
      _updateRequestStatus(id, 'rejected', 'reject');

  /// Marks a request as completed (terminal). Records `completed_at`.
  Future<void> markRequestCompleted(String id) => _updateRequestStatus(
        id,
        'completed',
        'complete',
        extra: {'completed_at': DateTime.now().toUtc().toIso8601String()},
      );

  /// Cancels a request (terminal owner action; distinct from rejecting an
  /// extracted item that was wrong).
  Future<void> cancelRequest(String id) =>
      _updateRequestStatus(id, 'cancelled', 'cancel');

  /// Adds/replaces the owner's private note on a request and audits it.
  Future<void> addOwnerNote(String id, String note) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('meal_requests')
        .update({'owner_note': note.trim()})
        .eq('id', id)
        .eq('owner_id', ownerId);
    await _writeAudit(
      entityType: 'meal_request',
      entityId: id,
      action: 'note',
      newData: {'owner_note': note.trim()},
    );
  }

  /// Bulk-approves the given requests, but only the ones whose sender is
  /// resolved. Unresolved senders are skipped (never silently approved); the
  /// returned record lets the UI report both counts.
  Future<({int approved, int skipped})> approveMany(List<String> ids) async {
    if (ids.isEmpty) return (approved: 0, skipped: 0);
    final ownerId = getCurrentOwnerId();
    // Read the candidates first so we can partition resolved vs. unresolved and
    // skip the unresolved ones even if the UI let them be selected.
    final rows = await _client
        .from('meal_requests')
        .select()
        .inFilter('id', ids)
        .eq('owner_id', ownerId);
    final candidates = rows
        .map((e) => MealRequest.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final approvable = candidates.where((r) => r.isApprovable).toList();
    final skipped = candidates.length - approvable.length;
    if (approvable.isEmpty) return (approved: 0, skipped: skipped);

    final updated = await _client
        .from('meal_requests')
        .update({'status': 'approved'})
        .inFilter('id', approvable.map((r) => r.id).toList())
        .eq('owner_id', ownerId)
        .select();
    // Auto-create ledger entries + audit each approved request.
    for (final row in updated) {
      final req = MealRequest.fromJson(Map<String, dynamic>.from(row));
      await _maybeCreateLedgerForApproved(req);
      await _writeAudit(
        entityType: 'meal_request',
        entityId: req.id,
        action: 'confirm',
        newData: {'status': 'approved', 'student_name': req.studentName},
      );
    }
    return (approved: updated.length, skipped: skipped);
  }

  /// Status transitions that confirm a request (and so may feed meal counts /
  /// the ledger). These are gated on [MealRequest.isApprovable]; reject/cancel
  /// stay open so the owner can always clear a bad extraction.
  static const _confirmingStatuses = {'approved', 'completed'};

  /// Shared status transition: reads the prior row (for the audit trail + the
  /// approval guard), updates, audits, and returns the refreshed request.
  /// Returns null if no matching owner-scoped row was found. Throws
  /// [UnresolvedSenderException] if an unresolved sender is being confirmed.
  Future<MealRequest?> _updateRequestStatus(
    String id,
    String status,
    String action, {
    Map<String, dynamic>? extra,
  }) async {
    final ownerId = getCurrentOwnerId();
    final beforeRow = await _client
        .from('meal_requests')
        .select()
        .eq('id', id)
        .eq('owner_id', ownerId)
        .maybeSingle();
    if (beforeRow == null) return null;
    final before = MealRequest.fromJson(Map<String, dynamic>.from(beforeRow));
    // Safety net: never let an unresolved/unlinked sender be confirmed, even if
    // the UI somehow offered the action.
    if (_confirmingStatuses.contains(status) && !before.isApprovable) {
      throw const UnresolvedSenderException();
    }
    final row = await _client
        .from('meal_requests')
        .update({'status': status, ...?extra})
        .eq('id', id)
        .eq('owner_id', ownerId)
        .select()
        .maybeSingle();
    if (row == null) return null;
    final req = MealRequest.fromJson(Map<String, dynamic>.from(row));
    await _writeAudit(
      entityType: 'meal_request',
      entityId: id,
      action: action,
      oldData: {'status': before.status},
      newData: {'status': status, 'student_name': req.studentName},
    );
    return req;
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
    final update = request.toEditableUpdate();
    final row = await _client
        .from('meal_requests')
        .update(update)
        .eq('id', request.id)
        .eq('owner_id', ownerId)
        .select()
        .single();
    final updated = MealRequest.fromJson(Map<String, dynamic>.from(row));
    await _writeAudit(
      entityType: 'meal_request',
      entityId: request.id,
      action: 'edit',
      newData: update,
    );
    return updated;
  }

  Future<void> deleteMealRequest(String id) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('meal_requests')
        .delete()
        .eq('id', id)
        .eq('owner_id', ownerId);
    await _writeAudit(
      entityType: 'meal_request',
      entityId: id,
      action: 'delete',
    );
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

  /// Links a meal request to a canonical student and (optionally) stores the
  /// request's extracted name as an alias so future imports of that spelling
  /// auto-link. The request's link_status is set to 'linked' and its review
  /// candidates are cleared.
  ///
  /// IMPORTANT: for duplicate-name ambiguity (two active "Rahul"s) the caller
  /// MUST pass [aliasToSave] as null. Saving "Rahul" globally would wrongly
  /// auto-link every future "Rahul" to this one student. We only persist an
  /// alias when the extracted spelling is a safe, non-generic hint.
  Future<void> linkRequestToStudent({
    required String requestId,
    required String studentId,
    required String canonicalName,
    String? aliasToSave,
  }) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('meal_requests')
        .update({
          'student_id': studentId,
          'student_name': canonicalName.trim(),
          'link_status': 'linked',
          'link_reason': 'Linked manually in sender review.',
          'candidate_student_ids': null,
        })
        .eq('id', requestId)
        .eq('owner_id', ownerId);
    if (aliasToSave != null && aliasToSave.trim().isNotEmpty) {
      await addAlias(studentId: studentId, alias: aliasToSave);
    }
  }

  /// The unclear/ambiguous senders from one import run that the owner still
  /// needs to resolve: requests whose sender could not be confidently linked to
  /// a single customer (link_status ambiguous / needs_review / unreliable_sender,
  /// or — for older rows — simply no linked student). Newest first.
  Future<List<MealRequest>> fetchUnclearRequestsForImport(
    String importId,
  ) async {
    final all = await fetchRequestsForImport(importId);
    return all.where((r) => r.isSenderUnresolved).toList();
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

  // --- Customers (stored in the `students` table) -------------------------

  /// All customers for this owner, with full lifecycle fields. Optional
  /// [status] filter ('active'|'paused'|'inactive') and name/phone [search].
  Future<List<Student>> fetchCustomers({String? status, String? search}) async {
    final ownerId = getCurrentOwnerId();
    var query = _client.from('students').select().eq('owner_id', ownerId);
    if (status != null && status != 'all') {
      query = query.eq('status', status);
    }
    final term = search?.trim() ?? '';
    if (term.isNotEmpty) {
      query = query.or('name.ilike.%$term%,phone.ilike.%$term%');
    }
    final rows = await query.order('name');
    return rows
        .map((e) => Student.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Customer counts grouped by status, for the dashboard tallies.
  Future<Map<String, int>> fetchCustomerStatusCounts() async {
    final ownerId = getCurrentOwnerId();
    final rows =
        await _client.from('students').select('status').eq('owner_id', ownerId);
    final counts = <String, int>{'active': 0, 'paused': 0, 'inactive': 0};
    for (final r in rows) {
      final s = r['status'] as String? ?? 'active';
      counts[s] = (counts[s] ?? 0) + 1;
    }
    return counts;
  }

  /// Creates a customer with full details (distinct from the thin
  /// [createStudent] used by the import/link flow).
  Future<Student> createCustomer({
    required String name,
    String phone = '',
    String roomOrAddress = '',
    String status = 'active',
    String notes = '',
    String? joinedAt,
  }) async {
    final ownerId = getCurrentOwnerId();
    final draft = Student(
      id: '',
      name: name,
      phone: phone,
      roomOrAddress: roomOrAddress,
      status: status,
      notes: notes,
      // Default the join date to today when the caller doesn't supply one.
      joinedAt: joinedAt ?? _dateStr(DateTime.now()),
    );
    final row = await _client
        .from('students')
        .insert({'owner_id': ownerId, ...draft.toWritable()})
        .select()
        .single();
    final created = Student.fromJson(Map<String, dynamic>.from(row));
    await _writeAudit(
      entityType: 'customer',
      entityId: created.id,
      action: 'create',
      newData: {'name': created.name, 'status': created.status},
    );
    return created;
  }

  /// Updates an existing customer's editable fields.
  Future<Student> updateCustomer(Student customer) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('students')
        .update(customer.toWritable())
        .eq('id', customer.id)
        .eq('owner_id', ownerId)
        .select()
        .single();
    final updated = Student.fromJson(Map<String, dynamic>.from(row));
    await _writeAudit(
      entityType: 'customer',
      entityId: customer.id,
      action: 'update',
      newData: {'name': updated.name, 'status': updated.status},
    );
    return updated;
  }

  /// Marks a customer active / paused / inactive, keeping the legacy `active`
  /// boolean in sync, and audits the transition.
  Future<void> setCustomerStatus(String id, String status) async {
    final ownerId = getCurrentOwnerId();
    final before = await _client
        .from('students')
        .select('status')
        .eq('id', id)
        .eq('owner_id', ownerId)
        .maybeSingle();
    await _client
        .from('students')
        .update({'status': status, 'active': status == 'active'})
        .eq('id', id)
        .eq('owner_id', ownerId);
    final action = switch (status) {
      'paused' => 'pause',
      'active' => 'resume',
      _ => 'status_change',
    };
    await _writeAudit(
      entityType: 'customer',
      entityId: id,
      action: action,
      oldData: before == null ? null : {'status': before['status']},
      newData: {'status': status},
    );
  }

  /// A single customer's request history (newest first).
  Future<List<MealRequest>> fetchCustomerRequests(String studentId) async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('meal_requests')
        .select()
        .eq('owner_id', ownerId)
        .eq('student_id', studentId)
        .order('created_at', ascending: false);
    return rows
        .map((e) => MealRequest.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  // --- Meal plans ---------------------------------------------------------

  Future<List<MealPlan>> fetchMealPlans({bool activeOnly = false}) async {
    final ownerId = getCurrentOwnerId();
    var query = _client.from('meal_plans').select().eq('owner_id', ownerId);
    if (activeOnly) query = query.eq('is_active', true);
    final rows = await query.order('created_at', ascending: false);
    return rows
        .map((e) => MealPlan.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<MealPlan> createMealPlan(MealPlan plan) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('meal_plans')
        .insert({'owner_id': ownerId, ...plan.toWritable()})
        .select()
        .single();
    final created = MealPlan.fromJson(Map<String, dynamic>.from(row));
    await _writeAudit(
      entityType: 'meal_plan',
      entityId: created.id,
      action: 'create',
      newData: {'name': created.name},
    );
    return created;
  }

  Future<MealPlan> updateMealPlan(MealPlan plan) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('meal_plans')
        .update(plan.toWritable())
        .eq('id', plan.id)
        .eq('owner_id', ownerId)
        .select()
        .single();
    final updated = MealPlan.fromJson(Map<String, dynamic>.from(row));
    await _writeAudit(
      entityType: 'meal_plan',
      entityId: plan.id,
      action: 'update',
      newData: {'name': updated.name},
    );
    return updated;
  }

  Future<void> deleteMealPlan(String id) async {
    final ownerId = getCurrentOwnerId();
    await _client
        .from('meal_plans')
        .delete()
        .eq('id', id)
        .eq('owner_id', ownerId);
    await _writeAudit(entityType: 'meal_plan', entityId: id, action: 'delete');
  }

  // --- Customer meal plans (assignments) ----------------------------------

  /// The customer's current active plan (with the plan joined in), or null.
  Future<CustomerMealPlan?> fetchActiveCustomerPlan(String studentId) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('customer_meal_plans')
        .select('*, meal_plans(*)')
        .eq('owner_id', ownerId)
        .eq('student_id', studentId)
        .eq('is_active', true)
        .maybeSingle();
    if (row == null) return null;
    return CustomerMealPlan.fromJson(Map<String, dynamic>.from(row));
  }

  /// Assigns [mealPlanId] to a customer as their active plan, ending any
  /// previous active assignment first (the unique partial index allows only
  /// one active plan per customer).
  Future<void> assignMealPlan({
    required String studentId,
    required String mealPlanId,
    String? startDate,
  }) async {
    final ownerId = getCurrentOwnerId();
    await _endActiveCustomerPlans(ownerId, studentId);
    await _client.from('customer_meal_plans').insert({
      'owner_id': ownerId,
      'student_id': studentId,
      'meal_plan_id': mealPlanId,
      'start_date': startDate ?? _dateStr(DateTime.now()),
      'is_active': true,
    });
    await _writeAudit(
      entityType: 'customer_meal_plan',
      entityId: studentId,
      action: 'assign_plan',
      newData: {'meal_plan_id': mealPlanId},
    );
  }

  /// Ends the customer's active plan without assigning a new one.
  Future<void> endCustomerPlan(String studentId) async {
    final ownerId = getCurrentOwnerId();
    await _endActiveCustomerPlans(ownerId, studentId);
    await _writeAudit(
      entityType: 'customer_meal_plan',
      entityId: studentId,
      action: 'update',
      newData: {'is_active': false},
    );
  }

  Future<void> _endActiveCustomerPlans(String ownerId, String studentId) async {
    await _client
        .from('customer_meal_plans')
        .update({'is_active': false, 'end_date': _dateStr(DateTime.now())})
        .eq('owner_id', ownerId)
        .eq('student_id', studentId)
        .eq('is_active', true);
  }

  // --- Kitchen summary ----------------------------------------------------

  /// Expected meal headcounts derived from active customers' active meal plans.
  /// Returns (fromPlans, breakfast, lunch, dinner): `fromPlans` is false when
  /// there is no plan data at all, so callers can fall back to base counts.
  Future<({bool fromPlans, int breakfast, int lunch, int dinner})>
      _expectedFromPlans(String ownerId) async {
    final rows = await _client
        .from('customer_meal_plans')
        .select(
            'is_active, meal_plans(breakfast_enabled,lunch_enabled,dinner_enabled), students(status)')
        .eq('owner_id', ownerId)
        .eq('is_active', true);
    var breakfast = 0, lunch = 0, dinner = 0;
    var any = false;
    for (final row in rows) {
      final student = row['students'];
      final status = student is Map ? student['status'] as String? : null;
      // Only active customers contribute to the expected kitchen count.
      if (status != null && status != 'active') continue;
      final plan = row['meal_plans'];
      if (plan is! Map) continue;
      any = true;
      if (plan['breakfast_enabled'] == true) breakfast++;
      if (plan['lunch_enabled'] == true) lunch++;
      if (plan['dinner_enabled'] == true) dinner++;
    }
    return (fromPlans: any, breakfast: breakfast, lunch: lunch, dinner: dinner);
  }

  /// Builds the breakfast/lunch/dinner kitchen plan for [date]: expected from
  /// active customer meal plans (fallback to base lunch/dinner counts), minus
  /// confirmed cancellations, plus confirmed extras.
  Future<KitchenSummary> fetchKitchenSummary({
    required String date,
    required int baseLunch,
    required int baseDinner,
  }) async {
    final ownerId = getCurrentOwnerId();
    final expected = await _expectedFromPlans(ownerId);
    final rows = await _client
        .from('meal_requests')
        .select()
        .eq('owner_id', ownerId)
        .eq('status', 'approved');
    final approved = rows
        .map((e) => MealRequest.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return _composeKitchen(
      date: date,
      expected: expected,
      baseLunch: baseLunch,
      baseDinner: baseDinner,
      approved: approved,
    );
  }

  /// Pure assembly of a [KitchenSummary] from already-fetched inputs, so the
  /// dashboard can reuse one approved-request fetch across today + tomorrow.
  KitchenSummary _composeKitchen({
    required String date,
    required ({bool fromPlans, int breakfast, int lunch, int dinner}) expected,
    required int baseLunch,
    required int baseDinner,
    required List<MealRequest> approved,
  }) {
    final expB = expected.fromPlans ? expected.breakfast : 0;
    final expL = expected.fromPlans ? expected.lunch : baseLunch;
    final expD = expected.fromPlans ? expected.dinner : baseDinner;

    // Reuse the daily counting rules for cancellations/additions on this date.
    // Breakfast is informational only (requests don't model it yet).
    final ds = DailySummary.compute(
      date: date,
      baseLunch: 0,
      baseDinner: 0,
      approvedRequests: approved,
      adjustments: const [],
    );
    return KitchenSummary(
      date: date,
      fromPlans: expected.fromPlans,
      breakfast: MealCount(expected: expB),
      lunch: MealCount(
          expected: expL, cancelled: ds.lunchCancelled, extra: ds.lunchAdded),
      dinner: MealCount(
          expected: expD, cancelled: ds.dinnerCancelled, extra: ds.dinnerAdded),
    );
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
    final scheduledCount = approved.length;

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

    // Customer status tallies + today/tomorrow kitchen plan.
    final customerCounts = await fetchCustomerStatusCounts();
    final expected = await _expectedFromPlans(ownerId);
    final tomorrow = _dateStr(DateTime.now().add(const Duration(days: 1)));
    final todayKitchen = _composeKitchen(
      date: today,
      expected: expected,
      baseLunch: baseLunch,
      baseDinner: baseDinner,
      approved: approved,
    );
    final tomorrowKitchen = _composeKitchen(
      date: tomorrow,
      expected: expected,
      baseLunch: baseLunch,
      baseDinner: baseDinner,
      approved: approved,
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
      scheduledCount: scheduledCount,
      activeCustomers: customerCounts['active'] ?? 0,
      pausedCustomers: customerCounts['paused'] ?? 0,
      importedCount: importedCount,
      latestImportAt: latestImportAt,
      today: todayKitchen,
      tomorrow: tomorrowKitchen,
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

  // --- Payments & customer balances ---------------------------------------

  /// Ledger entries for one customer, newest first. Unlike [fetchLedgerEntries]
  /// (which matches by name), this filters by the canonical `student_id`.
  Future<List<LedgerEntry>> fetchStudentLedgerEntries(String studentId) async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('ledger_entries')
        .select()
        .eq('owner_id', ownerId)
        .eq('student_id', studentId)
        .order('entry_date', ascending: false)
        .order('created_at', ascending: false);
    return rows
        .map((e) => LedgerEntry.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Payment rows, newest first. Scoped to one customer when [studentId] is set.
  Future<List<Payment>> fetchPayments({String? studentId}) async {
    final ownerId = getCurrentOwnerId();
    var query = _client.from('payments').select().eq('owner_id', ownerId);
    if (studentId != null) query = query.eq('student_id', studentId);
    final rows = await query
        .order('payment_date', ascending: false)
        .order('created_at', ascending: false);
    return rows
        .map((e) => Payment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Records a received payment against a customer. `owner_id` comes from the
  /// authenticated session (never the caller); RLS enforces owner isolation.
  Future<Payment> createPayment({
    required String studentId,
    required num amount,
    String? paymentDate,
    String? paymentMode,
    String note = '',
  }) async {
    final ownerId = getCurrentOwnerId();
    final row = await _client
        .from('payments')
        .insert({
          'owner_id': ownerId,
          'student_id': studentId,
          'amount': amount,
          'payment_date': paymentDate ?? _dateStr(DateTime.now()),
          if (paymentMode != null) 'payment_mode': paymentMode,
          'note': note.trim(),
        })
        .select()
        .single();
    final created = Payment.fromJson(Map<String, dynamic>.from(row));
    await _writeAudit(
      entityType: 'payment',
      entityId: created.id,
      action: 'payment_added',
      newData: {
        'student_id': studentId,
        'amount': amount,
        if (paymentMode != null) 'payment_mode': paymentMode,
      },
    );
    return created;
  }

  /// Adds a manual balance adjustment as a `ledger_entries` row (entry_type
  /// `manual_adjustment`). A positive amount increases what the customer owes;
  /// a negative amount credits them. Reuses the existing `note` field for text.
  Future<LedgerEntry> addManualAdjustment({
    required String studentName,
    String? studentId,
    required int amount,
    String description = '',
    String? entryDate,
  }) async {
    final ownerId = getCurrentOwnerId();
    final name = studentName.trim();
    final resolvedId = studentId ??
        (await _resolveStudentIds([name], ownerId))[_nameKey(name)];
    final row = await _client
        .from('ledger_entries')
        .insert({
          'owner_id': ownerId,
          'student_id': resolvedId,
          'student_name': name,
          'entry_type': 'manual_adjustment',
          'amount': amount,
          'note': description.trim(),
          'entry_date': entryDate ?? _dateStr(DateTime.now()),
        })
        .select()
        .single();
    final created = LedgerEntry.fromJson(Map<String, dynamic>.from(row));
    await _writeAudit(
      entityType: 'ledger_entry',
      entityId: created.id,
      action: 'manual_adjustment_added',
      newData: {
        if (resolvedId != null) 'student_id': resolvedId,
        'amount': amount,
        'note': description.trim(),
      },
    );
    return created;
  }

  /// Per-customer money positions for active + paused customers, combining the
  /// existing ledger convention with the payments table (see [CustomerBalance]).
  Future<List<CustomerBalance>> fetchCustomerBalances({String? search}) async {
    final ownerId = getCurrentOwnerId();
    var cq = _client
        .from('students')
        .select()
        .eq('owner_id', ownerId)
        .inFilter('status', ['active', 'paused']);
    final term = search?.trim() ?? '';
    if (term.isNotEmpty) {
      cq = cq.or('name.ilike.%$term%,phone.ilike.%$term%');
    }
    final customerRows = await cq.order('name');
    final customers = customerRows
        .map((e) => Student.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    if (customers.isEmpty) return [];

    final ids = customers.map((c) => c.id).toList();

    final ledgerRows = await _client
        .from('ledger_entries')
        .select()
        .eq('owner_id', ownerId)
        .inFilter('student_id', ids);
    final paymentRows = await _client
        .from('payments')
        .select()
        .eq('owner_id', ownerId)
        .inFilter('student_id', ids);

    final entriesByStudent = <String, List<LedgerEntry>>{};
    for (final r in ledgerRows) {
      final e = LedgerEntry.fromJson(Map<String, dynamic>.from(r));
      final sid = e.studentId;
      if (sid == null) continue;
      entriesByStudent.putIfAbsent(sid, () => []).add(e);
    }
    final paymentsByStudent = <String, List<Payment>>{};
    for (final r in paymentRows) {
      final p = Payment.fromJson(Map<String, dynamic>.from(r));
      paymentsByStudent.putIfAbsent(p.studentId, () => []).add(p);
    }

    return [
      for (final c in customers)
        CustomerBalance.from(
          c,
          entriesByStudent[c.id] ?? const [],
          paymentsByStudent[c.id] ?? const [],
        ),
    ];
  }

  // --- Monthly bills ------------------------------------------------------

  /// First day of [month]/[year] and of the following month, as 'YYYY-MM-DD'
  /// bounds for a half-open `[start, next)` range over the date columns.
  ({String start, String next}) _monthRange(int month, int year) {
    String two(int v) => v.toString().padLeft(2, '0');
    final nextMonth = month == 12 ? 1 : month + 1;
    final nextYear = month == 12 ? year + 1 : year;
    return (
      start: '${year.toString().padLeft(4, '0')}-${two(month)}-01',
      next: '${nextYear.toString().padLeft(4, '0')}-${two(nextMonth)}-01',
    );
  }

  /// Generated bills for [month]/[year], customer name/phone joined in, ordered
  /// by name. Owner-scoped.
  Future<List<MonthlyBill>> fetchMonthlyBills({
    required int month,
    required int year,
  }) async {
    final ownerId = getCurrentOwnerId();
    final rows = await _client
        .from('monthly_bills')
        .select('*, students(name, phone)')
        .eq('owner_id', ownerId)
        .eq('bill_month', month)
        .eq('bill_year', year);
    final bills = rows
        .map((e) => MonthlyBill.fromJson(Map<String, dynamic>.from(e)))
        .toList()
      ..sort((a, b) =>
          a.studentName.toLowerCase().compareTo(b.studentName.toLowerCase()));
    return bills;
  }

  /// The month's ledger entries + payments for one customer, newest first.
  /// Powers the bill-detail breakdown using the same inputs as [compute].
  Future<({List<LedgerEntry> entries, List<Payment> payments})>
      fetchBillBreakdown({
    required String studentId,
    required int month,
    required int year,
  }) async {
    final ownerId = getCurrentOwnerId();
    final range = _monthRange(month, year);
    final ledgerRows = await _client
        .from('ledger_entries')
        .select()
        .eq('owner_id', ownerId)
        .eq('student_id', studentId)
        .gte('entry_date', range.start)
        .lt('entry_date', range.next)
        .order('entry_date', ascending: false)
        .order('created_at', ascending: false);
    final paymentRows = await _client
        .from('payments')
        .select()
        .eq('owner_id', ownerId)
        .eq('student_id', studentId)
        .gte('payment_date', range.start)
        .lt('payment_date', range.next)
        .order('payment_date', ascending: false)
        .order('created_at', ascending: false);
    return (
      entries: ledgerRows
          .map((e) => LedgerEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      payments: paymentRows
          .map((e) => Payment.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  /// Computes and upserts monthly bills for [month]/[year]. With [studentId]
  /// set, generates that one customer's bill; otherwise every active or paused
  /// customer. Re-running is safe — the (owner, student, month, year) unique key
  /// makes this an update-in-place, never a duplicate. Returns the saved bills.
  Future<List<MonthlyBill>> generateMonthlyBills({
    required int month,
    required int year,
    String? studentId,
  }) async {
    final ownerId = getCurrentOwnerId();

    var customerQuery =
        _client.from('students').select().eq('owner_id', ownerId);
    if (studentId != null) {
      customerQuery = customerQuery.eq('id', studentId);
    } else {
      customerQuery = customerQuery.inFilter('status', ['active', 'paused']);
    }
    final customers = (await customerQuery)
        .map((e) => Student.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    if (customers.isEmpty) return [];
    final ids = customers.map((c) => c.id).toList();
    final range = _monthRange(month, year);

    // Batch the three inputs once for the whole set, then compute per customer.
    final planRows = await _client
        .from('customer_meal_plans')
        .select('student_id, meal_plans(monthly_price)')
        .eq('owner_id', ownerId)
        .eq('is_active', true)
        .inFilter('student_id', ids);
    final baseByStudent = <String, num>{};
    for (final r in planRows) {
      final plan = r['meal_plans'];
      baseByStudent[r['student_id'] as String] =
          plan is Map ? (plan['monthly_price'] as num? ?? 0) : 0;
    }

    final ledgerRows = await _client
        .from('ledger_entries')
        .select()
        .eq('owner_id', ownerId)
        .inFilter('student_id', ids)
        .gte('entry_date', range.start)
        .lt('entry_date', range.next);
    final entriesByStudent = <String, List<LedgerEntry>>{};
    for (final r in ledgerRows) {
      final e = LedgerEntry.fromJson(Map<String, dynamic>.from(r));
      if (e.studentId == null) continue;
      entriesByStudent.putIfAbsent(e.studentId!, () => []).add(e);
    }

    final paymentRows = await _client
        .from('payments')
        .select()
        .eq('owner_id', ownerId)
        .inFilter('student_id', ids)
        .gte('payment_date', range.start)
        .lt('payment_date', range.next);
    final paymentsByStudent = <String, List<Payment>>{};
    for (final r in paymentRows) {
      final p = Payment.fromJson(Map<String, dynamic>.from(r));
      paymentsByStudent.putIfAbsent(p.studentId, () => []).add(p);
    }

    // Which customers already had a bill, so we can audit generated vs updated.
    final existingRows = await _client
        .from('monthly_bills')
        .select('student_id')
        .eq('owner_id', ownerId)
        .eq('bill_month', month)
        .eq('bill_year', year)
        .inFilter('student_id', ids);
    final existing =
        existingRows.map((e) => e['student_id'] as String).toSet();

    final computed = [
      for (final c in customers)
        MonthlyBill.compute(
          studentId: c.id,
          studentName: c.name,
          studentPhone: c.phone,
          month: month,
          year: year,
          baseAmount: baseByStudent[c.id] ?? 0,
          monthEntries: entriesByStudent[c.id] ?? const [],
          monthPayments: paymentsByStudent[c.id] ?? const [],
        ),
    ];

    final saved = await _client
        .from('monthly_bills')
        .upsert(
          computed.map((b) => b.toUpsert(ownerId)).toList(),
          onConflict: 'owner_id,student_id,bill_month,bill_year',
        )
        .select('*, students(name, phone)');
    final savedBills = saved
        .map((e) => MonthlyBill.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    for (final b in savedBills) {
      await _writeAudit(
        entityType: 'monthly_bill',
        entityId: b.id,
        action: existing.contains(b.studentId)
            ? 'monthly_bill_updated'
            : 'monthly_bill_generated',
        newData: {
          'student_id': b.studentId,
          'bill_month': month,
          'bill_year': year,
          'final_amount': b.finalAmount,
          'status': b.status,
        },
      );
    }

    savedBills.sort((a, b) =>
        a.studentName.toLowerCase().compareTo(b.studentName.toLowerCase()));
    return savedBills;
  }

  // --- Retention / cleanup ------------------------------------------------

  /// Deletes this owner's old import history older than [retentionDays] and
  /// returns how many import records were removed. Covers both the current and
  /// the legacy import tables:
  ///   * `chat_imports` older than the cutoff (the current import-history flow).
  ///     Their `chat_messages` are removed automatically by the ON DELETE
  ///     CASCADE FK defined in migration 0008; extracted `meal_requests` are
  ///     KEPT — that FK is ON DELETE SET NULL, so deleting an import only
  ///     unlinks (never deletes) the requests it produced.
  ///   * legacy `imported_messages` older than the cutoff.
  ///
  /// Does NOT touch students/customers, meal_requests, ledger_entries, payments,
  /// monthly_bills, the owner profile or the auth account.
  Future<int> cleanupOldImportedMessages(int retentionDays) async {
    final ownerId = getCurrentOwnerId();
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays))
        .toIso8601String();

    // Current import history. chat_messages cascade-delete with their import;
    // meal_requests are preserved (their import_id is set to null by the FK).
    final deletedImports = await _client
        .from('chat_imports')
        .delete()
        .eq('owner_id', ownerId)
        .lt('created_at', cutoff)
        .select('id');

    // Legacy raw-text imports, kept around for older data.
    final deletedLegacy = await _client
        .from('imported_messages')
        .delete()
        .eq('owner_id', ownerId)
        .lt('created_at', cutoff)
        .select('id');

    return deletedImports.length + deletedLegacy.length;
  }
}
