/// "How much to cook" for a single meal on a given day:
/// expected (base / from plans) − cancelled + extra = final.
class MealCount {
  final int expected;
  final int cancelled;
  final int extra;

  const MealCount({
    this.expected = 0,
    this.cancelled = 0,
    this.extra = 0,
  });

  int get finalCount {
    final v = expected - cancelled + extra;
    return v < 0 ? 0 : v;
  }
}

/// Per-day kitchen plan covering lunch and dinner. Built by
/// [DatabaseService.fetchKitchenSummary] from active customer meal plans (when
/// present) plus confirmed cancellation/addition requests, falling back to the
/// owner's base lunch/dinner counts when no plan data exists.
class KitchenSummary {
  final String date; // 'YYYY-MM-DD'

  /// True when at least one active customer meal plan fed the expected counts;
  /// false means the figures fell back to the owner's base counts.
  final bool fromPlans;

  final MealCount lunch;
  final MealCount dinner;

  const KitchenSummary({
    required this.date,
    required this.fromPlans,
    required this.lunch,
    required this.dinner,
  });

  const KitchenSummary.empty(this.date)
      : fromPlans = false,
        lunch = const MealCount(),
        dinner = const MealCount();
}
