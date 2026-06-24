/// Default Priya Mess pricing, used as fallbacks when an active customer has no
/// assigned meal plan (or whose plan leaves a meal price unset). These are the
/// single source of truth for "what a customer is billed when nothing overrides
/// it" — the Ledger and monthly-bill generation both fall back to these.
class BillingDefaults {
  const BillingDefaults._();

  /// Per-meal base charges.
  static const int lunchPrice = 50;
  static const int dinnerPrice = 80;

  /// A full day (lunch + dinner). Kept explicit so callers don't re-derive it.
  static const int dailyFullPrice = lunchPrice + dinnerPrice; // 130

  /// Default monthly bill for an active customer with no custom plan.
  static const int monthlyBill = 3900;
}
