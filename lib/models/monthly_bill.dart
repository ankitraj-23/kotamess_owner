import 'ledger_entry.dart';
import 'payment.dart';

/// Mirror of a row in `monthly_bills` — one generated bill per customer per
/// month. The amount columns are split buckets that always satisfy:
///
///   final_amount = base + extra + adjustment - credit - paid
///
/// which is the same money convention the Ledger uses (see [CustomerBalance]):
/// a `payment`-type ledger row / `payments` row reduces what's owed; every
/// other ledger amount adds to it (negative adjustments/notes give credit).
class MonthlyBill {
  final String? id; // null for a freshly computed, not-yet-saved bill
  final String studentId;
  final String studentName; // from the joined `students` row (display only)
  final String studentPhone; // from the joined `students` row (display only)
  final int billMonth; // 1-12
  final int billYear;
  final num baseAmount;
  final num extraAmount;
  final num creditAmount;
  final num adjustmentAmount;
  final num paidAmount;
  final num finalAmount;
  final String status; // unpaid | partially_paid | paid | overdue
  final DateTime? generatedAt;
  final DateTime? updatedAt;

  const MonthlyBill({
    this.id,
    required this.studentId,
    this.studentName = '',
    this.studentPhone = '',
    required this.billMonth,
    required this.billYear,
    this.baseAmount = 0,
    this.extraAmount = 0,
    this.creditAmount = 0,
    this.adjustmentAmount = 0,
    this.paidAmount = 0,
    this.finalAmount = 0,
    this.status = 'unpaid',
    this.generatedAt,
    this.updatedAt,
  });

  factory MonthlyBill.fromJson(Map<String, dynamic> json) {
    final s = json['students'];
    final student = s is Map ? Map<String, dynamic>.from(s) : null;
    return MonthlyBill(
      id: json['id'] as String?,
      studentId: json['student_id'] as String? ?? '',
      studentName: student?['name'] as String? ?? '',
      studentPhone: student?['phone'] as String? ?? '',
      billMonth: (json['bill_month'] as num?)?.toInt() ?? 1,
      billYear: (json['bill_year'] as num?)?.toInt() ?? 2000,
      baseAmount: (json['base_amount'] as num?) ?? 0,
      extraAmount: (json['extra_amount'] as num?) ?? 0,
      creditAmount: (json['credit_amount'] as num?) ?? 0,
      adjustmentAmount: (json['adjustment_amount'] as num?) ?? 0,
      paidAmount: (json['paid_amount'] as num?) ?? 0,
      finalAmount: (json['final_amount'] as num?) ?? 0,
      status: json['status'] as String? ?? 'unpaid',
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  /// Total billed for the month before payments (what the bill "is").
  num get grossBill => baseAmount + extraAmount + adjustmentAmount - creditAmount;

  /// Outstanding amount, never shown negative (an over-paid bill pends 0).
  num get pending => finalAmount < 0 ? 0 : finalAmount;

  String get statusLabel => MonthlyBillVocab.statusLabel(status);
  String get monthLabel => MonthlyBillVocab.monthName(billMonth);
  String get periodLabel => '$monthLabel $billYear';

  /// Owner-writable columns for the upsert. `owner_id` always comes from the
  /// authenticated session (never the caller); id / timestamps are DB-managed.
  Map<String, dynamic> toUpsert(String ownerId) => {
        'owner_id': ownerId,
        'student_id': studentId,
        'bill_month': billMonth,
        'bill_year': billYear,
        'base_amount': baseAmount,
        'extra_amount': extraAmount,
        'credit_amount': creditAmount,
        'adjustment_amount': adjustmentAmount,
        'paid_amount': paidAmount,
        'final_amount': finalAmount,
        'status': status,
      };

  /// Copyable reminder text for the customer.
  String reminderMessage() {
    final name = studentName.trim().isEmpty ? 'there' : studentName.trim();
    return 'Hi $name, your $periodLabel mess bill is ₹${formatMoney(grossBill)}. '
        'Paid: ₹${formatMoney(paidAmount)}. Pending: ₹${formatMoney(pending)}. '
        'Please pay soon.';
  }

  /// THE bill formula — the single place the maths lives. Buckets one customer's
  /// ledger entries + payments for [month]/[year] into the bill columns,
  /// preserving the existing Ledger balance convention.
  static MonthlyBill compute({
    required String studentId,
    required String studentName,
    required String studentPhone,
    required int month,
    required int year,
    required num baseAmount,
    required List<LedgerEntry> monthEntries,
    required List<Payment> monthPayments,
  }) {
    num extra = 0, credit = 0, adjustment = 0, paid = 0;
    for (final e in monthEntries) {
      switch (e.entryType) {
        case 'payment':
          paid += e.amount;
          break;
        case 'due':
        case 'charge':
          extra += e.amount;
          break;
        case 'adjustment':
        case 'manual_adjustment':
          // Signed: positive raises the bill, negative gives credit.
          if (e.amount >= 0) {
            adjustment += e.amount;
          } else {
            credit += -e.amount;
          }
          break;
        default:
          // 'note' (or any other type): keep the raw-sign charge convention.
          if (e.amount > 0) {
            extra += e.amount;
          } else if (e.amount < 0) {
            credit += -e.amount;
          }
      }
    }
    for (final p in monthPayments) {
      paid += p.amount;
    }
    final finalAmount = baseAmount + extra + adjustment - credit - paid;
    return MonthlyBill(
      studentId: studentId,
      studentName: studentName,
      studentPhone: studentPhone,
      billMonth: month,
      billYear: year,
      baseAmount: baseAmount,
      extraAmount: extra,
      creditAmount: credit,
      adjustmentAmount: adjustment,
      paidAmount: paid,
      finalAmount: finalAmount,
      status: _statusFor(finalAmount: finalAmount, paid: paid),
    );
  }

  /// No due-date data exists yet, so `overdue` is never auto-assigned here.
  static String _statusFor({required num finalAmount, required num paid}) {
    if (finalAmount <= 0) return 'paid';
    if (paid > 0) return 'partially_paid';
    return 'unpaid';
  }
}

/// Allowed statuses + month names + labels, shared by service and UI.
class MonthlyBillVocab {
  const MonthlyBillVocab._();

  static const months = <String>[
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  static String monthName(int m) => (m >= 1 && m <= 12) ? months[m - 1] : '';

  static String statusLabel(String status) {
    switch (status) {
      case 'paid':
        return 'Paid';
      case 'partially_paid':
        return 'Partially paid';
      case 'overdue':
        return 'Overdue';
      default:
        return 'Unpaid';
    }
  }
}
