/// Tiny, dependency-free CSV helpers shared by the in-app exports.
///
/// Output follows RFC-4180: a field is wrapped in double-quotes only when it
/// contains a comma, a double-quote, or a line break, and any embedded
/// double-quote is doubled. Rows are joined with CRLF so the text pastes
/// cleanly into spreadsheets.
library;

/// Escapes a single CSV field. `null` becomes an empty field.
String csvEscape(Object? value) {
  final s = value?.toString() ?? '';
  if (s.contains(',') ||
      s.contains('"') ||
      s.contains('\n') ||
      s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

/// Builds CSV text from rows of cells. The first row is typically the header.
String rowsToCsv(List<List<Object?>> rows) =>
    rows.map((row) => row.map(csvEscape).join(',')).join('\r\n');
