import 'daily_adjustment.dart';
import 'meal_request.dart';

/// Computed "how much to cook" summary for a single date, derived from the
/// owner's base counts, the approved meal requests that resolve to that date,
/// and any manual daily adjustments.
///
/// Counting rules (only APPROVED requests count; pending/rejected never do):
///   cancel_meal       lunch/dinner/both -> that meal -1
///   both_meals_cancel -> lunch -1 and dinner -1
///   add_meal          lunch/dinner/both -> that meal +1
///   pause_mess        both/none -> lunch -1 and dinner -1 (lenient single-day)
///   resume_mess / dues_query / payment_note / generic_note / unclear
///                     -> informational only, never change the count
class DailySummary {
  final String date; // 'YYYY-MM-DD'
  final int baseLunch;
  final int baseDinner;

  final int lunchAdded;
  final int dinnerAdded;
  final int lunchCancelled;
  final int dinnerCancelled;
  final int manualLunch;
  final int manualDinner;

  /// Requests reducing/adding each meal, for the breakdown lists. A request that
  /// affects both meals (e.g. pause, both_meals_cancel) appears in both lists.
  final List<MealRequest> lunchCancellations;
  final List<MealRequest> dinnerCancellations;
  final List<MealRequest> additions;
  final List<MealRequest> notes;
  final List<MealRequest> needsDateReview;
  final List<DailyAdjustment> adjustments;

  DailySummary({
    required this.date,
    required this.baseLunch,
    required this.baseDinner,
    required this.lunchAdded,
    required this.dinnerAdded,
    required this.lunchCancelled,
    required this.dinnerCancelled,
    required this.manualLunch,
    required this.manualDinner,
    required this.lunchCancellations,
    required this.dinnerCancellations,
    required this.additions,
    required this.notes,
    required this.needsDateReview,
    required this.adjustments,
  });

  int get finalLunch {
    final v = baseLunch + lunchAdded - lunchCancelled + manualLunch;
    return v < 0 ? 0 : v;
  }

  int get finalDinner {
    final v = baseDinner + dinnerAdded - dinnerCancelled + manualDinner;
    return v < 0 ? 0 : v;
  }

  bool get hasAnyActivity =>
      lunchCancellations.isNotEmpty ||
      dinnerCancellations.isNotEmpty ||
      additions.isNotEmpty ||
      notes.isNotEmpty ||
      needsDateReview.isNotEmpty ||
      adjustments.isNotEmpty;

  static const _countAffecting = {
    'cancel_meal',
    'add_meal',
    'pause_mess',
    'both_meals_cancel',
  };

  /// Resolves the date a request applies to. Uses [MealRequest.requestDate]
  /// when present, otherwise anchors today/tomorrow labels to created_at.
  /// Returns null when the date is genuinely unclear.
  static DateTime? effectiveDate(MealRequest r) {
    final rd = r.requestDate;
    if (rd != null && rd.isNotEmpty) {
      final p = DateTime.tryParse(rd);
      if (p != null) return DateTime(p.year, p.month, p.day);
    }
    final label = (r.dateLabel ?? '').toLowerCase();
    final anchor = r.createdAt ?? DateTime.now();
    final anchorDate = DateTime(anchor.year, anchor.month, anchor.day);
    if (label.contains('today') || label.contains('aaj')) return anchorDate;
    if (label.contains('tomorrow') || label.contains('kal')) {
      return anchorDate.add(const Duration(days: 1));
    }
    return null;
  }

  factory DailySummary.compute({
    required String date,
    required int baseLunch,
    required int baseDinner,
    required List<MealRequest> approvedRequests,
    required List<DailyAdjustment> adjustments,
  }) {
    final selected = DateTime.tryParse(date);
    final selectedDate = selected == null
        ? null
        : DateTime(selected.year, selected.month, selected.day);

    final lunchCancellations = <MealRequest>[];
    final dinnerCancellations = <MealRequest>[];
    final additions = <MealRequest>[];
    final notes = <MealRequest>[];
    final needsDateReview = <MealRequest>[];

    var lunchAdded = 0;
    var dinnerAdded = 0;
    var lunchCancelled = 0;
    var dinnerCancelled = 0;

    bool sameDate(DateTime? eff) =>
        eff != null && selectedDate != null && eff == selectedDate;

    for (final r in approvedRequests) {
      final type = r.requestType;
      final meal = r.mealType;

      if (_countAffecting.contains(type)) {
        final eff = effectiveDate(r);
        if (eff == null) {
          needsDateReview.add(r);
          continue;
        }
        if (!sameDate(eff)) continue;

        switch (type) {
          case 'cancel_meal':
            if (meal == 'lunch' || meal == 'both') {
              lunchCancelled++;
              lunchCancellations.add(r);
            }
            if (meal == 'dinner' || meal == 'both') {
              dinnerCancelled++;
              dinnerCancellations.add(r);
            }
            break;
          case 'both_meals_cancel':
            lunchCancelled++;
            dinnerCancelled++;
            lunchCancellations.add(r);
            dinnerCancellations.add(r);
            break;
          case 'pause_mess':
            // Single-day, lenient: a pause for this date removes both meals.
            lunchCancelled++;
            dinnerCancelled++;
            lunchCancellations.add(r);
            dinnerCancellations.add(r);
            break;
          case 'add_meal':
            if (meal == 'lunch' || meal == 'both') lunchAdded++;
            if (meal == 'dinner' || meal == 'both') dinnerAdded++;
            additions.add(r);
            break;
        }
      } else {
        // Informational types: show only if dated to this day or undated.
        final eff = effectiveDate(r);
        if (eff == null || sameDate(eff)) notes.add(r);
      }
    }

    var manualLunch = 0;
    var manualDinner = 0;
    for (final a in adjustments) {
      if (a.meal == 'lunch' || a.meal == 'both') manualLunch += a.delta;
      if (a.meal == 'dinner' || a.meal == 'both') manualDinner += a.delta;
    }

    return DailySummary(
      date: date,
      baseLunch: baseLunch,
      baseDinner: baseDinner,
      lunchAdded: lunchAdded,
      dinnerAdded: dinnerAdded,
      lunchCancelled: lunchCancelled,
      dinnerCancelled: dinnerCancelled,
      manualLunch: manualLunch,
      manualDinner: manualDinner,
      lunchCancellations: lunchCancellations,
      dinnerCancellations: dinnerCancellations,
      additions: additions,
      notes: notes,
      needsDateReview: needsDateReview,
      adjustments: adjustments,
    );
  }
}
