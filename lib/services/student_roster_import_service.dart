import '../models/student.dart';
import 'name_utils.dart';

/// One validated row from a roster CSV, ready to be matched against existing
/// customers. [phone] is already normalized to a 10-digit Indian number (or ''
/// when absent/unparseable) and [normalizedName] is the identity key used for
/// duplicate detection.
class RosterImportRow {
  /// 1-based line in the source file (including the header), for issue reports.
  final int lineNumber;
  final String name;
  final String normalizedName;
  final String phone;
  final List<String> aliases;
  final int? monthlyAmount;
  final String status;

  /// Whether the CSV supplied an explicit, valid status for this row. When
  /// false we keep an existing customer's status untouched on update (so a
  /// status-less CSV never silently resurrects an inactive customer).
  final bool statusExplicit;

  /// Parsed for completeness; not persisted — there is no plan-name column on
  /// `students` and roster import intentionally does not create meal plans.
  final String planName;

  const RosterImportRow({
    required this.lineNumber,
    required this.name,
    required this.normalizedName,
    required this.phone,
    required this.aliases,
    required this.monthlyAmount,
    required this.status,
    required this.statusExplicit,
    required this.planName,
  });
}

enum RosterIssueKind { skipped, ambiguous }

/// What the importer should do with one row, decided purely from the current
/// roster snapshot (see [StudentRosterImport.decide]).
enum RosterAction { create, update, ambiguous }

class RosterDecision {
  final RosterAction action;

  /// Id of the customer to update (only for [RosterAction.update]).
  final String? targetId;

  /// Owner-facing reason (only for [RosterAction.ambiguous]).
  final String? reason;

  const RosterDecision.create()
      : action = RosterAction.create,
        targetId = null,
        reason = null;
  const RosterDecision.update(this.targetId)
      : action = RosterAction.update,
        reason = null;
  const RosterDecision.ambiguous(this.reason)
      : action = RosterAction.ambiguous,
        targetId = null;
}

/// The minimal view of an existing customer the matcher needs. Decouples the
/// matching rules from the `Student` model / Supabase so they can be unit
/// tested in isolation.
class RosterCandidate {
  final String id;
  final String normalizedName;
  final String normalizedPhone;
  final bool isActive;

  /// True when this customer was created earlier in the SAME import run.
  final bool createdThisRun;

  const RosterCandidate({
    required this.id,
    required this.normalizedName,
    required this.normalizedPhone,
    required this.isActive,
    required this.createdThisRun,
  });
}

/// A row that could not be imported cleanly, with an owner-facing [reason].
class RosterImportIssue {
  final int lineNumber;
  final String name;
  final RosterIssueKind kind;
  final String reason;

  const RosterImportIssue({
    required this.lineNumber,
    required this.name,
    required this.kind,
    required this.reason,
  });
}

/// Outcome of a roster import: how many customers were created/updated and the
/// rows that were skipped or left ambiguous for the owner to review.
class RosterImportResult {
  final int created;
  final int updated;
  final List<RosterImportIssue> issues;

  const RosterImportResult({
    required this.created,
    required this.updated,
    required this.issues,
  });

  int get skipped =>
      issues.where((i) => i.kind == RosterIssueKind.skipped).length;
  int get ambiguous =>
      issues.where((i) => i.kind == RosterIssueKind.ambiguous).length;
}

/// Parser for the owner's "Student roster import" CSV (an Excel export saved as
/// CSV). Pure and side-effect free — the database matching/insert work lives in
/// `DatabaseService.importStudentRoster`. Kept dependency-free (no `csv`
/// package) so it stays simple and unit-testable.
class StudentRosterImport {
  const StudentRosterImport._();

  /// Splits CSV [content] into validated [RosterImportRow]s plus parse-time
  /// issues (rows skipped for a missing name or a non-numeric amount). Throws
  /// [FormatException] when the file is empty or has no `name` column.
  static ({List<RosterImportRow> rows, List<RosterImportIssue> issues}) parse(
    String content,
  ) {
    final table = _tokenize(content)
        .where((r) => r.any((c) => c.trim().isNotEmpty))
        .toList();
    if (table.isEmpty) {
      throw const FormatException('The CSV file is empty.');
    }

    final header = table.first.map((h) => h.trim().toLowerCase()).toList();
    final col = <String, int>{};
    for (var i = 0; i < header.length; i++) {
      if (header[i].isNotEmpty) col.putIfAbsent(header[i], () => i);
    }
    if (!col.containsKey('name')) {
      throw const FormatException(
          'CSV must have a "name" column. Expected header: '
          'name,phone,aliases,plan_name,monthly_amount,status');
    }

    final rows = <RosterImportRow>[];
    final issues = <RosterImportIssue>[];

    for (var r = 1; r < table.length; r++) {
      final cells = table[r];
      final lineNumber = r + 1; // header is line 1
      String cell(String key) {
        final i = col[key];
        if (i == null || i >= cells.length) return '';
        return cells[i].trim();
      }

      final name = cell('name');
      if (name.isEmpty) {
        issues.add(RosterImportIssue(
          lineNumber: lineNumber,
          name: '',
          kind: RosterIssueKind.skipped,
          reason: 'Missing name',
        ));
        continue;
      }

      int? amount;
      final amountRaw = cell('monthly_amount');
      if (amountRaw.isNotEmpty) {
        final parsed = _parseAmount(amountRaw);
        if (parsed == null) {
          issues.add(RosterImportIssue(
            lineNumber: lineNumber,
            name: name,
            kind: RosterIssueKind.skipped,
            reason: 'monthly_amount "$amountRaw" is not a number',
          ));
          continue;
        }
        amount = parsed;
      }

      final statusRaw = cell('status').toLowerCase();
      final statusExplicit =
          statusRaw.isNotEmpty && Student.statuses.contains(statusRaw);

      rows.add(RosterImportRow(
        lineNumber: lineNumber,
        name: name,
        normalizedName: NameUtils.normalize(name),
        phone: normalizePhone(cell('phone')),
        aliases: _splitAliases(cell('aliases')),
        monthlyAmount: amount,
        status: statusExplicit ? statusRaw : 'active',
        statusExplicit: statusExplicit,
        planName: cell('plan_name'),
      ));
    }

    return (rows: rows, issues: issues);
  }

  /// Decides what to do with [row] given the current [snapshot] of customers
  /// (including any created earlier in this run). Pure and conservative — this
  /// is where same-name ambiguity is protected:
  ///
  ///   * A unique phone match always wins (update); multiple phone matches are
  ///     ambiguous.
  ///   * A phone-bearing row with no phone match only enriches a single
  ///     pre-existing same-name customer that has NO phone yet; otherwise it is
  ///     a distinct person → create. (Two "Rahul Kumar" rows with different
  ///     phones therefore become two separate customers.)
  ///   * A row with no phone updates a single pre-existing active same-name
  ///     customer; if several share that name → ambiguous. If we already
  ///     created a same-name no-phone customer in THIS run, the duplicate is
  ///     ambiguous, never merged.
  static RosterDecision decide(
    RosterImportRow row,
    List<RosterCandidate> snapshot,
  ) {
    if (row.phone.isNotEmpty) {
      final byPhone =
          snapshot.where((c) => c.normalizedPhone == row.phone).toList();
      if (byPhone.length == 1) return RosterDecision.update(byPhone.first.id);
      if (byPhone.length > 1) {
        return RosterDecision.ambiguous(
            'Phone ${row.phone} already matches ${byPhone.length} customers');
      }
      // No phone match: only enrich a single pre-existing same-name customer
      // that has no phone yet; otherwise treat as a distinct person.
      final pre = _preExistingActiveByName(row, snapshot);
      if (pre.length == 1 && pre.first.normalizedPhone.isEmpty) {
        return RosterDecision.update(pre.first.id);
      }
      return const RosterDecision.create();
    }

    // No phone: match by unique pre-existing active name only.
    final pre = _preExistingActiveByName(row, snapshot);
    if (pre.length == 1) return RosterDecision.update(pre.first.id);
    if (pre.length > 1) {
      return RosterDecision.ambiguous(
          '${pre.length} active customers already named "${row.name}" — '
          'add a phone to disambiguate');
    }
    // No pre-existing match. If we already created a same-name no-phone row in
    // THIS file, do not merge into it — flag the duplicate for review.
    final dupInRun = snapshot.any((c) =>
        c.createdThisRun &&
        c.normalizedPhone.isEmpty &&
        c.normalizedName == row.normalizedName);
    if (dupInRun) {
      return RosterDecision.ambiguous(
          'Duplicate name "${row.name}" with no phone in this file — '
          'add a phone to import as a separate customer');
    }
    return const RosterDecision.create();
  }

  static List<RosterCandidate> _preExistingActiveByName(
    RosterImportRow row,
    List<RosterCandidate> snapshot,
  ) =>
      snapshot
          .where((c) =>
              c.isActive &&
              !c.createdThisRun &&
              c.normalizedName == row.normalizedName)
          .toList();

  /// Normalizes a phone number to a bare 10-digit Indian mobile number, or ''
  /// when it has no recognizable 10-digit form. Tolerates +91 / 0 / 91
  /// prefixes, spaces, dashes and brackets.
  static String normalizePhone(String raw) {
    var d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.isEmpty) return '';
    if (d.length == 13 && d.startsWith('091')) {
      d = d.substring(3);
    } else if (d.length == 12 && d.startsWith('91')) {
      d = d.substring(2);
    } else if (d.length == 11 && d.startsWith('0')) {
      d = d.substring(1);
    }
    return d.length == 10 ? d : '';
  }

  /// Splits an aliases cell on `/`, `,` or `;`, trimming and dropping empties
  /// and case-insensitive duplicates.
  static List<String> _splitAliases(String raw) {
    if (raw.trim().isEmpty) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final part in raw.split(RegExp(r'[/,;]'))) {
      final t = part.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  /// Parses a money cell ("4500", "4,500", "₹4500", "4500.0") to a rounded int,
  /// or null when it is not numeric.
  static int? _parseAmount(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[,\s₹]'), '');
    if (cleaned.isEmpty) return null;
    final v = num.tryParse(cleaned);
    return v?.round();
  }

  /// Minimal RFC-4180 CSV tokenizer: handles quoted fields, "" escaped quotes,
  /// and commas/newlines inside quotes. Returns rows of raw (untrimmed) fields.
  static List<List<String>> _tokenize(String input) {
    final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < normalized.length; i++) {
      final c = normalized[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < normalized.length && normalized[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field.toString());
        field = StringBuffer();
      } else if (c == '\n') {
        row.add(field.toString());
        rows.add(row);
        row = <String>[];
        field = StringBuffer();
      } else {
        field.write(c);
      }
    }
    row.add(field.toString());
    rows.add(row);
    return rows;
  }
}
