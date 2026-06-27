// Unit tests for date-range meal pause/cancellation: model parsing/display and
// the DailySummary range counting. Pure Dart, no Supabase needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:kotamess_owner/models/daily_summary.dart';
import 'package:kotamess_owner/models/meal_request.dart';

MealRequest _pause({
  required String start,
  String? end,
  int lunchDelta = -1,
  int dinnerDelta = -1,
}) {
  return MealRequest(
    id: 'r-$start-$end',
    ownerId: 'owner-1',
    studentId: 'stud-1',
    studentName: 'Aman',
    originalMessage: 'kal se ek hafte tak khana mat dena',
    requestType: 'both_meals_cancel',
    mealType: 'both',
    lunchDelta: lunchDelta,
    dinnerDelta: dinnerDelta,
    requestDate: start,
    requestEndDate: end,
    dateLabel: null,
    status: 'approved',
    confidence: 1.0,
    reason: '',
    source: 'paste',
    createdAt: DateTime.parse(start),
    linkStatus: 'linked',
  );
}

DailySummary _summaryOn(String date, List<MealRequest> requests) =>
    DailySummary.compute(
      date: date,
      baseLunch: 40,
      baseDinner: 40,
      approvedRequests: requests,
      adjustments: const [],
    );

void main() {
  group('MealRequest range model', () {
    test('parses request_end_date and exposes range helpers', () {
      final r = MealRequest.fromJson({
        'id': 'a',
        'owner_id': 'o',
        'student_name': 'Aman',
        'request_type': 'both_meals_cancel',
        'meal_type': 'both',
        'lunch_delta': -1,
        'dinner_delta': -1,
        'request_date': '2026-06-28',
        'request_end_date': '2026-07-04',
      });
      expect(r.requestEndDate, '2026-07-04');
      expect(r.effectiveEndDate, '2026-07-04');
      expect(r.isRangeRequest, isTrue);
      expect(r.dateRangeDisplay, '28 Jun – 4 Jul');
    });

    test('single-day request has no range', () {
      final r = MealRequest.fromJson({
        'id': 'b',
        'owner_id': 'o',
        'student_name': 'Aman',
        'request_type': 'cancel_meal',
        'meal_type': 'lunch',
        'lunch_delta': -1,
        'request_date': '2026-06-28',
      });
      expect(r.requestEndDate, isNull);
      expect(r.effectiveEndDate, '2026-06-28');
      expect(r.isRangeRequest, isFalse);
      expect(r.dateRangeDisplay, '2026-06-28');
    });

    test('toEditableUpdate carries request_end_date', () {
      final r = _pause(start: '2026-06-28', end: '2026-07-04');
      expect(r.toEditableUpdate()['request_end_date'], '2026-07-04');
    });
  });

  group('DailySummary date-range counting', () {
    // "kal se ek hafte tak khana mat dena": 2026-06-28 .. 2026-07-04, both -1.
    final week = _pause(start: '2026-06-28', end: '2026-07-04');

    test('counts on the start day', () {
      final s = _summaryOn('2026-06-28', [week]);
      expect(s.finalLunch, 39);
      expect(s.finalDinner, 39);
    });

    test('counts on the second day of the range', () {
      final s = _summaryOn('2026-06-29', [week]);
      expect(s.finalLunch, 39);
      expect(s.finalDinner, 39);
    });

    test('counts on a middle day inside the range', () {
      final s = _summaryOn('2026-07-01', [week]);
      expect(s.finalLunch, 39);
      expect(s.finalDinner, 39);
    });

    test('counts on the inclusive end day', () {
      final s = _summaryOn('2026-07-04', [week]);
      expect(s.finalLunch, 39);
      expect(s.finalDinner, 39);
    });

    test('does NOT count the day before the range', () {
      final s = _summaryOn('2026-06-27', [week]);
      expect(s.finalLunch, 40);
      expect(s.finalDinner, 40);
    });

    test('does NOT count the day after the range', () {
      final s = _summaryOn('2026-07-05', [week]);
      expect(s.finalLunch, 40);
      expect(s.finalDinner, 40);
    });

    test('single-day request (no end date) only counts on its day', () {
      final single = _pause(start: '2026-06-28', end: null);
      expect(_summaryOn('2026-06-28', [single]).finalLunch, 39);
      expect(_summaryOn('2026-06-29', [single]).finalLunch, 40);
    });
  });
}
