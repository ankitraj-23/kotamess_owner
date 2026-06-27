/// Mirrors a row in `meal_requests` (post-0003 schema).
///
/// DB stores plain strings for [requestType] / [mealType] / [status]; we keep
/// them as strings here and expose label/lookup helpers rather than enums so
/// the model stays a thin, forgiving mirror of the table.
class MealRequest {
  final String id;
  final String ownerId;
  String? studentId;
  String studentName;
  final String originalMessage;
  String requestType;
  String mealType;

  /// Signed quantity change for each meal (0003+ quantity deltas, 0014).
  ///   +N  -> add N of that meal
  ///   -N  -> remove / cancel N of that meal
  ///    0  -> no change for that meal
  /// e.g. "kal do lunch extra dena" -> [lunchDelta] = +2, [dinnerDelta] = 0.
  int lunchDelta;
  int dinnerDelta;

  String? requestDate; // 'YYYY-MM-DD' or null — START date of the request

  /// Inclusive END date for a multi-day pause/cancel (0015). null = single-day
  /// request (treat as [requestDate]). The per-meal [lunchDelta]/[dinnerDelta]
  /// apply to every day in [requestDate]..[requestEndDate].
  String? requestEndDate;

  String? dateLabel;
  String status;
  final double confidence;
  String reason;
  String ownerNote;
  final String source;
  final DateTime? createdAt;
  final DateTime? completedAt;

  /// Links back to the `chat_imports` run that produced this request (0008).
  final String? importId;

  /// Duplicate flag set during import: 'unique' | 'possible_duplicate' |
  /// 'duplicate' (0008). Defaults to 'unique' for older rows.
  final String duplicateStatus;

  /// Late-request flagging set by the extract-requests Edge Function (0010).
  /// [isLateRequest] is true when the message arrived after [cutoffAt]
  /// (meal time − owner cutoff). The request still stays pending — late only
  /// flags it for review, it is never auto-rejected.
  final bool isLateRequest;
  final DateTime? cutoffAt;
  final DateTime? messageReceivedAt;
  final String? lateReason;

  /// Sender-linking metadata set by the extract-requests Edge Function (0011).
  /// [senderRaw] is the WhatsApp sender exactly as exported; [linkStatus] is one
  /// of 'linked' | 'needs_review' | 'ambiguous' | 'unreliable_sender' (null for
  /// rows imported before this feature). [candidateStudentIds] are the customer
  /// ids the owner can choose from when the sender is ambiguous / needs review.
  final String? senderRaw;
  final String? senderNormalized;
  final String? linkStatus;
  final String? linkReason;
  final List<String> candidateStudentIds;

  MealRequest({
    required this.id,
    required this.ownerId,
    required this.studentId,
    required this.studentName,
    required this.originalMessage,
    required this.requestType,
    required this.mealType,
    this.lunchDelta = 0,
    this.dinnerDelta = 0,
    required this.requestDate,
    this.requestEndDate,
    required this.dateLabel,
    required this.status,
    required this.confidence,
    required this.reason,
    this.ownerNote = '',
    required this.source,
    required this.createdAt,
    this.completedAt,
    this.importId,
    this.duplicateStatus = 'unique',
    this.isLateRequest = false,
    this.cutoffAt,
    this.messageReceivedAt,
    this.lateReason,
    this.senderRaw,
    this.senderNormalized,
    this.linkStatus,
    this.linkReason,
    this.candidateStudentIds = const [],
  });

  factory MealRequest.fromJson(Map<String, dynamic> json) {
    return MealRequest(
      id: json['id'] as String,
      ownerId: json['owner_id'] as String? ?? '',
      studentId: json['student_id'] as String?,
      studentName: json['student_name'] as String? ?? 'Unknown',
      originalMessage: json['original_message'] as String? ?? '',
      requestType: json['request_type'] as String? ?? 'unclear',
      mealType: json['meal_type'] as String? ?? 'none',
      lunchDelta: (json['lunch_delta'] as num?)?.toInt() ?? 0,
      dinnerDelta: (json['dinner_delta'] as num?)?.toInt() ?? 0,
      requestDate: json['request_date'] as String?,
      requestEndDate: json['request_end_date'] as String?,
      dateLabel: json['date_label'] as String?,
      status: json['status'] as String? ?? 'pending',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      reason: json['reason'] as String? ?? '',
      ownerNote: json['owner_note'] as String? ?? '',
      source: json['source'] as String? ?? 'paste',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      completedAt: DateTime.tryParse(json['completed_at'] as String? ?? ''),
      importId: json['import_id'] as String?,
      duplicateStatus: json['duplicate_status'] as String? ?? 'unique',
      isLateRequest: json['is_late_request'] as bool? ?? false,
      cutoffAt: DateTime.tryParse(json['cutoff_at'] as String? ?? ''),
      messageReceivedAt:
          DateTime.tryParse(json['message_received_at'] as String? ?? ''),
      lateReason: json['late_reason'] as String?,
      senderRaw: json['sender_raw'] as String?,
      senderNormalized: json['sender_normalized'] as String?,
      linkStatus: json['link_status'] as String?,
      linkReason: json['link_reason'] as String?,
      candidateStudentIds: (json['candidate_student_ids'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  /// Editable fields only — used by the Requests "edit" action.
  Map<String, dynamic> toEditableUpdate() {
    return {
      'student_name': studentName.trim(),
      'request_type': requestType,
      'meal_type': mealType,
      'lunch_delta': lunchDelta,
      'dinner_delta': dinnerDelta,
      'request_date': requestDate,
      'request_end_date': requestEndDate,
      'date_label': dateLabel,
      'reason': reason.trim(),
      'owner_note': ownerNote.trim(),
    };
  }

  String get requestTypeLabel => MealRequestVocab.typeLabel(requestType);
  String get mealTypeLabel => MealRequestVocab.mealLabel(mealType);
  String get statusLabel => MealRequestVocab.statusLabel(status);

  /// True when this request carries an explicit quantity change for either meal.
  bool get hasQuantityChange => lunchDelta != 0 || dinnerDelta != 0;

  /// True when the owner entered this request by hand (call / in-person /
  /// outside the WhatsApp group) rather than importing it from a chat.
  bool get isManual => source == 'manual';

  /// Short signed labels for the request card chips, e.g. "Lunch +2",
  /// "Dinner -1". Returns null for a meal with no change so the card can skip
  /// the chip (a 0 delta is not shown prominently).
  String? get lunchDeltaLabel =>
      lunchDelta == 0 ? null : 'Lunch ${_signed(lunchDelta)}';
  String? get dinnerDeltaLabel =>
      dinnerDelta == 0 ? null : 'Dinner ${_signed(dinnerDelta)}';

  static String _signed(int v) => v > 0 ? '+$v' : '$v';

  /// The single source of truth for "may this request be approved/confirmed?".
  /// A request is approvable only when it resolves to a real customer:
  ///   * [studentId] is set, AND
  ///   * [linkStatus] is 'linked' — or null/empty for legacy rows imported
  ///     before the 0011 sender metadata (those already carry a student_id).
  /// Ambiguous / needs_review / unreliable_sender rows (and any row with no
  /// linked student) are NOT approvable until the owner links them.
  bool get isApprovable {
    if (studentId == null) return false;
    final ls = linkStatus;
    if (ls == null || ls.isEmpty) return true; // legacy row, already linked
    return ls == 'linked';
  }

  /// True when the WhatsApp sender could NOT be confidently linked to a single
  /// customer, so the owner must resolve it in the review flow before the
  /// request can be approved or counted. The exact inverse of [isApprovable].
  bool get isSenderUnresolved => !isApprovable;

  /// True only for the duplicate-saved-name case ("two students named Rahul").
  /// Drives the nudge that asks Priya to rename duplicate WhatsApp contacts.
  bool get isAmbiguousSender => linkStatus == 'ambiguous';

  /// True when the WhatsApp sender itself is unreliable (e.g. a bare phone
  /// number or a group/system event) — we must never auto-create a customer
  /// from it; the owner has to link/resolve it manually.
  bool get isUnreliableSender => linkStatus == 'unreliable_sender';

  /// True when there are existing customers the owner can pick from to resolve
  /// this request (set by the import sender-linking pass).
  bool get hasResolveCandidates => candidateStudentIds.isNotEmpty;

  /// Whether it is safe to one-tap "Create customer & approve" from this
  /// request. Only for the plain needs_review / unlinked case with a usable
  /// name — never for ambiguous duplicates or unreliable senders, and never
  /// for an empty / "Unknown" name.
  bool get canCreateCustomerFromName {
    if (isAmbiguousSender || isUnreliableSender) return false;
    final n = studentName.trim();
    if (n.isEmpty) return false;
    return n.toLowerCase() != 'unknown';
  }

  String get linkStatusLabel {
    switch (linkStatus) {
      case 'linked':
        return 'Linked';
      case 'ambiguous':
        return 'Ambiguous name';
      case 'unreliable_sender':
        return 'Unclear sender';
      case 'needs_review':
        return 'Needs review';
      default:
        return studentId == null ? 'Not linked' : 'Linked';
    }
  }

  bool get isDuplicateFlagged => duplicateStatus != 'unique';
  String get duplicateStatusLabel {
    switch (duplicateStatus) {
      case 'duplicate':
        return 'Duplicate';
      case 'possible_duplicate':
        return 'Possible duplicate';
      default:
        return 'Unique';
    }
  }

  String get dateDisplay {
    if (requestDate != null && requestDate!.isNotEmpty) return requestDate!;
    final label = dateLabel?.trim();
    return (label == null || label.isEmpty) ? 'unspecified' : label;
  }

  /// The effective end of the request's date range: [requestEndDate] when set,
  /// otherwise the start date (a single-day request).
  String? get effectiveEndDate {
    final e = requestEndDate;
    if (e != null && e.isNotEmpty) return e;
    return requestDate;
  }

  /// True when this request spans more than one day (a real range).
  bool get isRangeRequest {
    final start = requestDate;
    final end = effectiveEndDate;
    return start != null && end != null && start.isNotEmpty && end != start;
  }

  /// Date display that shows a range when applicable, e.g. "28 Jun – 04 Jul";
  /// otherwise falls back to the single-day [dateDisplay].
  String get dateRangeDisplay {
    if (!isRangeRequest) return dateDisplay;
    return '${_shortDate(requestDate!)} – ${_shortDate(effectiveEndDate!)}';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// 'YYYY-MM-DD' -> '28 Jun'. Returns the raw string if it can't be parsed.
  static String _shortDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.day} ${_months[d.month - 1]}';
  }
}

/// Allowed values + human labels shared by models, services and UI.
class MealRequestVocab {
  const MealRequestVocab._();

  static const requestTypes = <String>[
    'cancel_meal',
    'add_meal',
    'pause_mess',
    'resume_mess',
    'both_meals_cancel',
    'dues_query',
    'payment_note',
    'generic_note',
    'unclear',
  ];

  static const mealTypes = <String>['lunch', 'dinner', 'both', 'none'];

  /// Lifecycle states. `pending` == needs review, `approved` == confirmed /
  /// scheduled; `completed`/`cancelled` are owner-driven terminal states.
  static const statuses = <String>[
    'pending',
    'approved',
    'completed',
    'cancelled',
    'rejected',
  ];

  static String typeLabel(String type) {
    switch (type) {
      case 'cancel_meal':
        return 'Cancel meal';
      case 'add_meal':
        return 'Add meal';
      case 'pause_mess':
        return 'Pause mess';
      case 'resume_mess':
        return 'Resume mess';
      case 'both_meals_cancel':
        return 'Cancel both meals';
      case 'dues_query':
        return 'Dues query';
      case 'payment_note':
        return 'Payment note';
      case 'generic_note':
        return 'Note';
      default:
        return 'Needs review';
    }
  }

  static String mealLabel(String meal) {
    switch (meal) {
      case 'lunch':
        return 'Lunch';
      case 'dinner':
        return 'Dinner';
      case 'both':
        return 'Lunch + Dinner';
      default:
        return '—';
    }
  }

  static String statusLabel(String status) {
    switch (status) {
      case 'approved':
        return 'Confirmed';
      case 'completed':
        return 'Completed';
      case 'cancelled':
        return 'Cancelled';
      case 'rejected':
        return 'Rejected';
      default:
        return 'Needs review';
    }
  }
}
