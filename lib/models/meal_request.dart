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
  String? requestDate; // 'YYYY-MM-DD' or null
  String? dateLabel;
  String status;
  final double confidence;
  String reason;
  String ownerNote;
  final String source;
  final DateTime? createdAt;
  final DateTime? completedAt;

  MealRequest({
    required this.id,
    required this.ownerId,
    required this.studentId,
    required this.studentName,
    required this.originalMessage,
    required this.requestType,
    required this.mealType,
    required this.requestDate,
    required this.dateLabel,
    required this.status,
    required this.confidence,
    required this.reason,
    this.ownerNote = '',
    required this.source,
    required this.createdAt,
    this.completedAt,
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
      requestDate: json['request_date'] as String?,
      dateLabel: json['date_label'] as String?,
      status: json['status'] as String? ?? 'pending',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      reason: json['reason'] as String? ?? '',
      ownerNote: json['owner_note'] as String? ?? '',
      source: json['source'] as String? ?? 'paste',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      completedAt: DateTime.tryParse(json['completed_at'] as String? ?? ''),
    );
  }

  /// Editable fields only — used by the Requests "edit" action.
  Map<String, dynamic> toEditableUpdate() {
    return {
      'student_name': studentName.trim(),
      'request_type': requestType,
      'meal_type': mealType,
      'request_date': requestDate,
      'date_label': dateLabel,
      'reason': reason.trim(),
      'owner_note': ownerNote.trim(),
    };
  }

  String get requestTypeLabel => MealRequestVocab.typeLabel(requestType);
  String get mealTypeLabel => MealRequestVocab.mealLabel(mealType);
  String get statusLabel => MealRequestVocab.statusLabel(status);

  String get dateDisplay {
    if (requestDate != null && requestDate!.isNotEmpty) return requestDate!;
    final label = dateLabel?.trim();
    return (label == null || label.isEmpty) ? 'unspecified' : label;
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
