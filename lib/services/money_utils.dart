/// Conservative Indian-rupee amount parsing for payment messages.
///
/// Designed to under-detect rather than over-detect: when unsure it returns 0
/// so the caller records a note instead of inventing a money figure.
class MoneyUtils {
  const MoneyUtils._();

  // Plausible mess-payment band. Below this is likely a day/quantity ("2 din");
  // above it is likely a phone / UPI reference number, not an amount.
  static const _minAmount = 50;
  static const _maxAmount = 200000;

  /// Parses an amount from free text. Prefers a currency-tagged number
  /// (₹/Rs/Rupees/INR); otherwise takes the largest standalone number that
  /// falls in the plausible payment band. Returns 0 when nothing qualifies.
  static int parseAmount(String text) {
    final lower = text.toLowerCase();

    // 1. Currency-tagged amount wins (e.g. "₹1500", "rs. 1,500", "inr 800").
    final tagged =
        RegExp(r'(?:₹|rs\.?|rupees|inr)\s*([0-9][0-9,]*)').firstMatch(lower);
    if (tagged != null) {
      final v = _toInt(tagged.group(1));
      if (v >= 1 && v <= _maxAmount) return v;
    }

    // 2. Otherwise the largest standalone number in the payment band. Requires
    //    at least two digits so single-digit counts ("2 din") are ignored.
    final candidates = RegExp(r'\b[0-9][0-9,]+\b')
        .allMatches(lower)
        .map((m) => _toInt(m.group(0)))
        .where((n) => n >= _minAmount && n <= _maxAmount)
        .toList()
      ..sort();
    return candidates.isEmpty ? 0 : candidates.last;
  }

  static int _toInt(String? s) =>
      int.tryParse((s ?? '').replaceAll(',', '')) ?? 0;
}
