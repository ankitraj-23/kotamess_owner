/// Deterministic name normalization + token helpers used for student matching
/// and aliases. Kept intentionally simple and side-effect free so the same
/// input always yields the same key on every device.
class NameUtils {
  const NameUtils._();

  /// Honorifics / address noise that should not affect identity matching.
  /// Stripped only as whole tokens, never as substrings (so "Sirsa" survives).
  static const _noiseTokens = <String>{
    'bhai',
    'bhaiya',
    'bhaisaab',
    'ji',
    'sir',
    'madam',
    'mess',
  };

  /// trim → lowercase → strip punctuation → collapse spaces → drop honorifics.
  /// Returns '' for names that are only noise (e.g. "bhai").
  static String normalize(String raw) {
    final cleaned = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '';
    final tokens =
        cleaned.split(' ').where((t) => !_noiseTokens.contains(t)).toList();
    return tokens.join(' ');
  }

  /// Normalized, de-duplicated word tokens — used for partial candidate match.
  static Set<String> tokens(String raw) {
    final n = normalize(raw);
    if (n.isEmpty) return <String>{};
    return n.split(' ').toSet();
  }

  /// True when two names plausibly refer to the same student: identical after
  /// normalization, or one name's token set is a subset of the other (e.g.
  /// "Amit" ⊂ "Amit Sharma"). The caller decides whether a partial overlap is
  /// strong enough to act on automatically.
  static bool isPossibleMatch(String a, String b) {
    final na = normalize(a);
    final nb = normalize(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    final ta = na.split(' ').toSet();
    final tb = nb.split(' ').toSet();
    return ta.intersection(tb).isNotEmpty &&
        (ta.containsAll(tb) || tb.containsAll(ta));
  }
}
