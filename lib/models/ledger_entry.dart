/// Mirror of a row in `ledger_entries`. The Ledger screen records simple,
/// owner-typed entries against a student name; linking to a `students` row is
/// optional, so [studentName] is the reliable display field.
class LedgerEntry {
  final String id;
  final String ownerId;
  String? studentId;
  String studentName;
  String entryType; // payment | due | adjustment | note
  int amount;
  String note;
  final String entryDate; // 'YYYY-MM-DD'
  final String? requestId; // set when auto-created from an approved request
  final DateTime? createdAt;

  LedgerEntry({
    required this.id,
    required this.ownerId,
    required this.studentId,
    required this.studentName,
    required this.entryType,
    required this.amount,
    required this.note,
    required this.entryDate,
    required this.requestId,
    required this.createdAt,
  });

  factory LedgerEntry.fromJson(Map<String, dynamic> json) {
    return LedgerEntry(
      id: json['id'] as String,
      ownerId: json['owner_id'] as String? ?? '',
      studentId: json['student_id'] as String?,
      studentName: json['student_name'] as String? ?? '',
      entryType: json['entry_type'] as String? ?? 'note',
      amount: (json['amount'] as num?)?.toInt() ?? 0,
      note: json['note'] as String? ?? '',
      entryDate: json['entry_date'] as String? ?? '',
      requestId: json['meal_request_id'] as String?,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
    );
  }

  /// True when this entry was generated from an approved WhatsApp request.
  bool get fromRequest => requestId != null;

  String get entryTypeLabel => LedgerVocab.typeLabel(entryType);

  /// Payments reduce what a student owes; dues/charges increase it. Notes and
  /// adjustments are signed by their amount.
  int get signedBalanceImpact {
    switch (entryType) {
      case 'payment':
        return -amount;
      case 'due':
      case 'charge':
        return amount;
      default:
        return amount; // adjustment / note: use raw sign
    }
  }
}

/// Allowed ledger entry types + labels, shared by service and UI.
class LedgerVocab {
  const LedgerVocab._();

  static const entryTypes = <String>['payment', 'due', 'adjustment', 'note'];

  static String typeLabel(String type) {
    switch (type) {
      case 'payment':
        return 'Payment';
      case 'due':
      case 'charge':
        return 'Due';
      case 'adjustment':
        return 'Adjustment';
      default:
        return 'Note';
    }
  }
}
