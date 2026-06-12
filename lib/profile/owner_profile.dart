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
    this.createdAt,
  });

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
    };
  }

  OwnerProfile copyWith({
    String? ownerName,
    String? messName,
    String? phone,
    int? retentionDays,
    int? defaultLunchCount,
    int? defaultDinnerCount,
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
      createdAt: createdAt,
    );
  }
}
