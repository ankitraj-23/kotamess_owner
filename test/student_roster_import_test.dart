// Unit tests for the roster CSV parser (pure, no Supabase needed).

import 'package:flutter_test/flutter_test.dart';
import 'package:kotamess_owner/services/student_roster_import_service.dart';

void main() {
  group('normalizePhone', () {
    test('keeps a clean 10-digit number', () {
      expect(StudentRosterImport.normalizePhone('9876543210'), '9876543210');
    });
    test('strips +91 / 91 / 0 prefixes and separators', () {
      expect(StudentRosterImport.normalizePhone('+91 98765-43210'), '9876543210');
      expect(StudentRosterImport.normalizePhone('919876543210'), '9876543210');
      expect(StudentRosterImport.normalizePhone('09876543210'), '9876543210');
    });
    test('returns empty for unparseable numbers', () {
      expect(StudentRosterImport.normalizePhone(''), '');
      expect(StudentRosterImport.normalizePhone('12345'), '');
    });
  });

  group('parse', () {
    test('parses the example roster with quoted aliases', () {
      const csv = 'name,phone,aliases,plan_name,monthly_amount,status\n'
          'Rahul Kumar,9876543210,"Rahul/Rahul K",Monthly Full Meal,4500,active\n'
          'Rahul Kumar,9876549999,"Rahul Hostel B",Monthly Full Meal,4500,active\n'
          'Aman Singh,,"Aman",Monthly Lunch Only,2500,active\n';
      final parsed = StudentRosterImport.parse(csv);
      expect(parsed.issues, isEmpty);
      expect(parsed.rows, hasLength(3));

      final r1 = parsed.rows[0];
      expect(r1.name, 'Rahul Kumar');
      expect(r1.phone, '9876543210');
      expect(r1.aliases, ['Rahul', 'Rahul K']);
      expect(r1.monthlyAmount, 4500);
      expect(r1.status, 'active');

      // Two Rahul Kumar rows with different phones stay distinct.
      expect(parsed.rows[1].phone, '9876549999');
      expect(parsed.rows[0].phone != parsed.rows[1].phone, isTrue);

      // No phone is parsed as empty, not an error.
      expect(parsed.rows[2].phone, '');
    });

    test('supports / , ; alias separators and drops empties/dupes', () {
      const csv = 'name,aliases\nA,"x; y , z / x /"\n';
      final parsed = StudentRosterImport.parse(csv);
      expect(parsed.rows.single.aliases, ['x', 'y', 'z']);
    });

    test('skips rows with a missing name', () {
      const csv = 'name,phone\n,9876543210\nReal,9876543211\n';
      final parsed = StudentRosterImport.parse(csv);
      expect(parsed.rows, hasLength(1));
      expect(parsed.issues, hasLength(1));
      expect(parsed.issues.single.kind, RosterIssueKind.skipped);
    });

    test('skips rows with a non-numeric monthly_amount', () {
      const csv = 'name,monthly_amount\nBad,abc\nGood,3000\n';
      final parsed = StudentRosterImport.parse(csv);
      expect(parsed.rows.single.name, 'Good');
      expect(parsed.rows.single.monthlyAmount, 3000);
      expect(parsed.issues.single.reason, contains('not a number'));
    });

    test('defaults status to active and marks it non-explicit', () {
      const csv = 'name,status\nNoStatus,\nPaused,paused\n';
      final parsed = StudentRosterImport.parse(csv);
      expect(parsed.rows[0].status, 'active');
      expect(parsed.rows[0].statusExplicit, isFalse);
      expect(parsed.rows[1].status, 'paused');
      expect(parsed.rows[1].statusExplicit, isTrue);
    });

    test('throws when the name column is missing', () {
      expect(() => StudentRosterImport.parse('phone\n123\n'),
          throwsA(isA<FormatException>()));
    });
  });

  group('decide (same-name ambiguity protection)', () {
    RosterImportRow rowOf({String name = 'Rahul Kumar', String phone = ''}) =>
        StudentRosterImport
            .parse('name,phone\n$name,$phone\n')
            .rows
            .single;

    RosterCandidate cand({
      required String id,
      String name = 'Rahul Kumar',
      String phone = '',
      bool active = true,
      bool createdThisRun = false,
    }) =>
        RosterCandidate(
          id: id,
          normalizedName: name.toLowerCase(),
          normalizedPhone: StudentRosterImport.normalizePhone(phone),
          isActive: active,
          createdThisRun: createdThisRun,
        );

    test('two different-phone rows with the same name stay separate', () {
      // First row: empty roster → create.
      final d1 = StudentRosterImport.decide(
          rowOf(phone: '9876543210'), const []);
      expect(d1.action, RosterAction.create);

      // Second row: a same-name customer with a DIFFERENT phone already exists.
      final d2 = StudentRosterImport.decide(
        rowOf(phone: '9876549999'),
        [cand(id: 'a', phone: '9876543210')],
      );
      expect(d2.action, RosterAction.create);
    });

    test('re-importing the same phone updates, never duplicates', () {
      final d = StudentRosterImport.decide(
        rowOf(phone: '9876543210'),
        [cand(id: 'a', phone: '9876543210')],
      );
      expect(d.action, RosterAction.update);
      expect(d.targetId, 'a');
    });

    test('duplicate same-name no-phone rows in one file are not merged', () {
      // Simulate the first no-phone row already created in this run.
      final d = StudentRosterImport.decide(
        rowOf(),
        [cand(id: 'a', createdThisRun: true)],
      );
      expect(d.action, RosterAction.ambiguous);
    });

    test('no-phone row with several pre-existing same-name actives is ambiguous',
        () {
      final d = StudentRosterImport.decide(
        rowOf(),
        [cand(id: 'a'), cand(id: 'b')],
      );
      expect(d.action, RosterAction.ambiguous);
    });

    test('no-phone row updates a single pre-existing same-name active', () {
      final d = StudentRosterImport.decide(rowOf(), [cand(id: 'a')]);
      expect(d.action, RosterAction.update);
      expect(d.targetId, 'a');
    });

    test('phone row enriches a pre-existing same-name customer with no phone',
        () {
      final d = StudentRosterImport.decide(
        rowOf(phone: '9876543210'),
        [cand(id: 'a', phone: '')],
      );
      expect(d.action, RosterAction.update);
      expect(d.targetId, 'a');
    });
  });
}
