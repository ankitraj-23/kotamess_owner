/// Mirror of a row in the `owner_profiles` table.
class OwnerProfile {
  final String id;
  final String email;
  final String ownerName;
  final String messName;
  final String phone;
  final int retentionDays;
  final int defaultLunchCount;
  final int defaultDinnerCount;

  /// Daily meal serving times, stored as `'HH:mm'`.
  final String breakfastTime;
  final String lunchTime;
  final String dinnerTime;

  /// Minutes before a meal that a student request must arrive; later requests
  /// are flagged for review. Defaults to 60 (1 hour) — never hardcode 1 hour
  /// elsewhere, read this value.
  final int requestCutoffMinutes;

  final DateTime? createdAt;

  const OwnerProfile({
    required this.id,
    required this.email,
    required this.ownerName,
    required this.messName,
    required this.phone,
    required this.retentionDays,
    this.defaultLunchCount = 0,
    this.defaultDinnerCount = 0,
    this.breakfastTime = '08:00',
    this.lunchTime = '13:00',
    this.dinnerTime = '20:00',
    this.requestCutoffMinutes = 60,
    this.createdAt,
  });

  /// Postgres `time` values come back as `'HH:mm:ss'`; trim to `'HH:mm'` and
  /// fall back to the given default for null/garbage.
  static String _time(dynamic value, String fallback) {
    final s = value as String?;
    if (s == null || s.length < 5) return fallback;
    return s.substring(0, 5);
  }

  factory OwnerProfile.fromJson(Map<String, dynamic> json) {
    return OwnerProfile(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      ownerName: json['owner_name'] as String? ?? '',
      messName: json['mess_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      retentionDays: (json['retention_days'] as num?)?.toInt() ?? 90,
      defaultLunchCount: (json['default_lunch_count'] as num?)?.toInt() ?? 0,
      defaultDinnerCount: (json['default_dinner_count'] as num?)?.toInt() ?? 0,
      breakfastTime: _time(json['breakfast_time'], '08:00'),
      lunchTime: _time(json['lunch_time'], '13:00'),
      dinnerTime: _time(json['dinner_time'], '20:00'),
      requestCutoffMinutes:
          (json['request_cutoff_minutes'] as num?)?.toInt() ?? 60,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
    );
  }

  /// Columns we are allowed to write from the client (id is the auth uid and
  /// is set server-side via the default / RLS check).
  Map<String, dynamic> toInsert() {
    return {
      'id': id,
      'email': email,
      'owner_name': ownerName,
      'mess_name': messName,
      'phone': phone,
      'retention_days': retentionDays,
      'default_lunch_count': defaultLunchCount,
      'default_dinner_count': defaultDinnerCount,
    };
  }

  /// Editable fields written from the Settings screen (never the id/email).
  Map<String, dynamic> toUpdate() {
    return {
      'owner_name': ownerName,
      'mess_name': messName,
      'phone': phone,
      'retention_days': retentionDays,
      'default_lunch_count': defaultLunchCount,
      'default_dinner_count': defaultDinnerCount,
      'breakfast_time': breakfastTime,
      'lunch_time': lunchTime,
      'dinner_time': dinnerTime,
      'request_cutoff_minutes': requestCutoffMinutes,
    };
  }

  OwnerProfile copyWith({
    String? ownerName,
    String? messName,
    String? phone,
    int? retentionDays,
    int? defaultLunchCount,
    int? defaultDinnerCount,
    String? breakfastTime,
    String? lunchTime,
    String? dinnerTime,
    int? requestCutoffMinutes,
  }) {
    return OwnerProfile(
      id: id,
      email: email,
      ownerName: ownerName ?? this.ownerName,
      messName: messName ?? this.messName,
      phone: phone ?? this.phone,
      retentionDays: retentionDays ?? this.retentionDays,
      defaultLunchCount: defaultLunchCount ?? this.defaultLunchCount,
      defaultDinnerCount: defaultDinnerCount ?? this.defaultDinnerCount,
      breakfastTime: breakfastTime ?? this.breakfastTime,
      lunchTime: lunchTime ?? this.lunchTime,
      dinnerTime: dinnerTime ?? this.dinnerTime,
      requestCutoffMinutes: requestCutoffMinutes ?? this.requestCutoffMinutes,
      createdAt: createdAt,
    );
  }
}
