/// A customer (called a "student" throughout this mess-management codebase).
///
/// `name` is the display/canonical name; alternate spellings live in
/// `student_aliases` and link back here. The lifecycle fields (status,
/// roomOrAddress, notes, joinedAt) back the Customers screen; the thin
/// link/merge flows still construct a [Student] from just `{id, name}`, so
/// every field beyond those two is optional with a sensible default.
class Student {
  final String id;
  final String name;
  final String phone;
  final String roomOrAddress;
  final String status; // active | inactive | paused
  final String notes;
  final String? joinedAt; // 'YYYY-MM-DD' or null
  final int monthlyPlan;
  final int balance;
  final DateTime? createdAt;

  const Student({
    required this.id,
    required this.name,
    this.phone = '',
    this.roomOrAddress = '',
    this.status = 'active',
    this.notes = '',
    this.joinedAt,
    this.monthlyPlan = 0,
    this.balance = 0,
    this.createdAt,
  });

  bool get isActive => status == 'active';

  factory Student.fromJson(Map<String, dynamic> json) => Student(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        // Prefer the new field; fall back to the legacy `area` column.
        roomOrAddress: (json['room_or_address'] as String?)?.trim().isNotEmpty ==
                true
            ? json['room_or_address'] as String
            : (json['area'] as String? ?? ''),
        status: json['status'] as String? ??
            ((json['active'] as bool? ?? true) ? 'active' : 'inactive'),
        notes: json['notes'] as String? ?? '',
        joinedAt: json['joined_at'] as String?,
        monthlyPlan: (json['monthly_plan'] as num?)?.toInt() ?? 0,
        balance: (json['balance'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );

  Student copyWith({
    String? name,
    String? phone,
    String? roomOrAddress,
    String? status,
    String? notes,
    String? joinedAt,
    int? monthlyPlan,
    int? balance,
  }) {
    return Student(
      id: id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      roomOrAddress: roomOrAddress ?? this.roomOrAddress,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      joinedAt: joinedAt ?? this.joinedAt,
      monthlyPlan: monthlyPlan ?? this.monthlyPlan,
      balance: balance ?? this.balance,
      createdAt: createdAt,
    );
  }

  /// Owner-writable fields for create/update. `active` is kept in sync with
  /// `status` so older code that still reads the boolean stays correct.
  Map<String, dynamic> toWritable() => {
        'name': name.trim(),
        'phone': phone.trim(),
        'room_or_address': roomOrAddress.trim(),
        // Mirror into the legacy `area` column too for backward compatibility.
        'area': roomOrAddress.trim(),
        'status': status,
        'active': status == 'active',
        'notes': notes.trim(),
        'joined_at': joinedAt,
      };

  static String statusLabel(String status) => switch (status) {
        'active' => 'Active',
        'paused' => 'Paused',
        'inactive' => 'Inactive',
        _ => status,
      };

  static const statuses = <String>['active', 'paused', 'inactive'];
}

/// How a candidate student matched the name being looked up. Drives both the
/// ordering of suggestions and how confidently the UI can act.
enum StudentMatchKind { exact, alias, partial }

/// A suggested existing student for an incoming/typed name, with the reason it
/// surfaced so the link UI can explain "Amit → Amit Sharma".
class StudentCandidate {
  final Student student;
  final StudentMatchKind kind;

  /// The alias text that matched, when [kind] is [StudentMatchKind.alias].
  final String? matchedAlias;

  const StudentCandidate({
    required this.student,
    required this.kind,
    this.matchedAlias,
  });

  String get reasonLabel => switch (kind) {
        StudentMatchKind.exact => 'Same name',
        StudentMatchKind.alias =>
          'Known alias${matchedAlias == null ? '' : ' “$matchedAlias”'}',
        StudentMatchKind.partial => 'Possible match',
      };
}
