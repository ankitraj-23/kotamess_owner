/// Mirror of a row in `daily_adjustments` — a manual per-day, per-meal delta
/// the owner adds on the Daily screen (e.g. "+2 lunch, walk-in guests").
class DailyAdjustment {
  final String id;
  final String ownerId;
  final String adjustmentDate; // 'YYYY-MM-DD'
  final String meal; // 'lunch' | 'dinner' | 'both'
  final int delta;
  final String reason;
  final DateTime? createdAt;

  DailyAdjustment({
    required this.id,
    required this.ownerId,
    required this.adjustmentDate,
    required this.meal,
    required this.delta,
    required this.reason,
    required this.createdAt,
  });

  factory DailyAdjustment.fromJson(Map<String, dynamic> json) {
    return DailyAdjustment(
      id: json['id'] as String,
      ownerId: json['owner_id'] as String? ?? '',
      adjustmentDate: json['adjustment_date'] as String? ?? '',
      meal: json['meal'] as String? ?? 'both',
      delta: (json['delta'] as num?)?.toInt() ?? 0,
      reason: json['reason'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
    );
  }

  String get mealLabel {
    switch (meal) {
      case 'lunch':
        return 'Lunch';
      case 'dinner':
        return 'Dinner';
      default:
        return 'Lunch + Dinner';
    }
  }

  String get deltaLabel => delta >= 0 ? '+$delta' : '$delta';
}
