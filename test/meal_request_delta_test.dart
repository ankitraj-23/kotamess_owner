// Unit tests for quantity-based lunch/dinner deltas: model JSON/labels and the
// DailySummary count math. Pure Dart, no Supabase needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:kotamess_owner/models/daily_summary.dart';
import 'package:kotamess_owner/models/meal_request.dart';

MealRequest _req({
  required String type,
  required String meal,
  int lunchDelta = 0,
  int dinnerDelta = 0,
  String requestDate = '2026-06-27',
  String? studentId = 'stud-1',
}) {
  return MealRequest(
    id: 'r-${DateTime.now().microsecondsSinceEpoch}-$meal$type',
    ownerId: 'owner-1',
    studentId: studentId,
    studentName: 'Test',
    originalMessage: 'msg',
    requestType: type,
    mealType: meal,
    lunchDelta: lunchDelta,
    dinnerDelta: dinnerDelta,
    requestDate: requestDate,
    dateLabel: null,
    status: 'approved',
    confidence: 1.0,
    reason: '',
    source: 'paste',
    createdAt: DateTime.parse('2026-06-27'),
    linkStatus: 'linked',
  );
}

void main() {
  group('MealRequest delta JSON + labels', () {
    test('parses lunch_delta / dinner_delta from JSON', () {
      final r = MealRequest.fromJson({
        'id': 'a',
        'owner_id': 'o',
        'student_name': 'X',
        'request_type': 'add_meal',
        'meal_type': 'lunch',
        'lunch_delta': 2,
        'dinner_delta': 0,
      });
      expect(r.lunchDelta, 2);
      expect(r.dinnerDelta, 0);
      expect(r.hasQuantityChange, isTrue);
      expect(r.lunchDeltaLabel, 'Lunch +2');
      expect(r.dinnerDeltaLabel, isNull);
    });

    test('negative delta renders a signed label', () {
      final r = _req(type: 'cancel_meal', meal: 'dinner', dinnerDelta: -1);
      expect(r.dinnerDeltaLabel, 'Dinner -1');
      expect(r.lunchDeltaLabel, isNull);
    });

    test('toEditableUpdate carries the deltas to the DB payload', () {
      final r = _req(type: 'add_meal', meal: 'lunch', lunchDelta: 3);
      final update = r.toEditableUpdate();
      expect(update['lunch_delta'], 3);
      expect(update['dinner_delta'], 0);
    });
  });

  group('DailySummary applies quantity deltas', () {
    test('base 40 with +3 and -2 lunch deltas -> 41 to prepare', () {
      final summary = DailySummary.compute(
        date: '2026-06-27',
        baseLunch: 40,
        baseDinner: 40,
        approvedRequests: [
          _req(type: 'add_meal', meal: 'lunch', lunchDelta: 3),
          _req(type: 'cancel_meal', meal: 'lunch', lunchDelta: -2),
        ],
        adjustments: const [],
      );
      expect(summary.finalLunch, 41);
      expect(summary.lunchAdded, 3);
      expect(summary.lunchCancelled, 2);
      expect(summary.finalDinner, 40);
    });

    test('edited dinner change of -2 reflects in the count', () {
      final summary = DailySummary.compute(
        date: '2026-06-27',
        baseLunch: 10,
        baseDinner: 10,
        approvedRequests: [
          _req(type: 'cancel_meal', meal: 'dinner', dinnerDelta: -2),
        ],
        adjustments: const [],
      );
      expect(summary.finalDinner, 8);
      expect(summary.dinnerCancelled, 2);
      expect(summary.dinnerCancellations, hasLength(1));
    });

    test('pause_mess still removes one of each meal (no delta needed)', () {
      final summary = DailySummary.compute(
        date: '2026-06-27',
        baseLunch: 5,
        baseDinner: 5,
        approvedRequests: [
          _req(type: 'pause_mess', meal: 'both'),
        ],
        adjustments: const [],
      );
      expect(summary.finalLunch, 4);
      expect(summary.finalDinner, 4);
    });

    test('unresolved sender never moves the count', () {
      final summary = DailySummary.compute(
        date: '2026-06-27',
        baseLunch: 5,
        baseDinner: 5,
        approvedRequests: [
          _req(
            type: 'add_meal',
            meal: 'lunch',
            lunchDelta: 2,
            studentId: null,
          ),
        ],
        adjustments: const [],
      );
      expect(summary.finalLunch, 5);
    });
  });
}
