import 'ledger_entry.dart';
import 'student.dart';

/// Mirror of a row in `payments` — money actually received from a customer.
/// Always linked to a customer ([studentId] is NOT NULL in the schema), which
/// is why payments are recorded from a customer's ledger detail, not by name.
class Payment {
  final String id;
  final String ownerId;
  final String studentId;
  final num amount;
  final String paymentDate; // 'YYYY-MM-DD'
  final String? paymentMode; // cash | upi | bank | card | other | null
  final String note;
  final DateTime? createdAt;

  const Payment({
    required this.id,
    required this.ownerId,
    required this.studentId,
    required this.amount,
    required this.paymentDate,
    required this.paymentMode,
    required this.note,
    required this.createdAt,
  });

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
        id: json['id'] as String,
        ownerId: json['owner_id'] as String? ?? '',
        studentId: json['student_id'] as String? ?? '',
        amount: (json['amount'] as num?) ?? 0,
        paymentDate: json['payment_date'] as String? ?? '',
        paymentMode: json['payment_mode'] as String?,
        note: json['note'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );

  String get modeLabel => PaymentVocab.modeLabel(paymentMode);
}

/// Allowed payment modes + labels, shared by service and UI.
class PaymentVocab {
  const PaymentVocab._();

  static const modes = <String>['cash', 'upi', 'bank', 'card', 'other'];

  static String modeLabel(String? mode) {
    switch (mode) {
      case 'cash':
        return 'Cash';
      case 'upi':
        return 'UPI';
      case 'bank':
        return 'Bank';
      case 'card':
        return 'Card';
      case 'other':
        return 'Other';
      default:
        return '—';
    }
  }
}

/// Aggregated money position for one customer, combining the existing
/// `ledger_entries` convention with the `payments` table.
///
/// Balance convention (preserves the existing ledger semantics):
///   * charges/dues raise what the customer owes  → counted in [totalCharges]
///   * a ledger `payment` row OR a `payments` row → counted in [totalPayments]
///   * balance = totalCharges - totalPayments      → positive means they owe
class CustomerBalance {
  final Student student;
  final num totalCharges;
  final num totalPayments;

  const CustomerBalance({
    required this.student,
    required this.totalCharges,
    required this.totalPayments,
  });

  /// Positive = customer owes this much; negative = customer is in credit.
  num get balance => totalCharges - totalPayments;
  bool get owes => balance > 0;
  bool get inCredit => balance < 0;

  /// Copyable reminder text for the customer's outstanding balance.
  String reminderMessage() {
    final name = student.name.trim().isEmpty ? 'there' : student.name.trim();
    return 'Hi $name, your pending mess balance is ₹${formatMoney(balance)}. '
        'Please clear it soon.';
  }

  /// Charge contribution of a single ledger entry. A `payment`-type ledger row
  /// counts as a payment (see [paymentOf]); everything else uses the existing
  /// signed convention where the raw amount adds to what the customer owes.
  static num chargeOf(LedgerEntry e) => e.entryType == 'payment' ? 0 : e.amount;

  /// Payment contribution of a single ledger entry (only `payment`-type rows).
  static num paymentOf(LedgerEntry e) => e.entryType == 'payment' ? e.amount : 0;

  /// Builds a balance from a customer's ledger entries and payment rows using
  /// the single shared formula above, so the list and detail views always agree.
  factory CustomerBalance.from(
    Student student,
    List<LedgerEntry> entries,
    List<Payment> payments,
  ) {
    num charges = 0;
    num paid = 0;
    for (final e in entries) {
      charges += chargeOf(e);
      paid += paymentOf(e);
    }
    for (final p in payments) {
      paid += p.amount;
    }
    return CustomerBalance(
      student: student,
      totalCharges: charges,
      totalPayments: paid,
    );
  }
}

/// Formats a money value with no trailing `.0` for whole rupees.
String formatMoney(num v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2);
}
