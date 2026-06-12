/// A canonical student row. `name` is the display/canonical name; alternate
/// spellings live in `student_aliases` and link back here.
class Student {
  final String id;
  final String name;

  const Student({required this.id, required this.name});

  factory Student.fromJson(Map<String, dynamic> json) => Student(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
      );
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
