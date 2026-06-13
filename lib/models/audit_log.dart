/// Mirror of a row in `audit_logs` — an append-only record of an important
/// owner action (request confirmed, customer paused, plan changed, …).
class AuditLog {
  final String id;
  final String entityType; // 'meal_request' | 'customer' | 'meal_plan' | ...
  final String? entityId;
  final String action;
  final Map<String, dynamic>? oldData;
  final Map<String, dynamic>? newData;
  final DateTime? createdAt;

  const AuditLog({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.action,
    this.oldData,
    this.newData,
    this.createdAt,
  });

  factory AuditLog.fromJson(Map<String, dynamic> json) => AuditLog(
        id: json['id'] as String,
        entityType: json['entity_type'] as String? ?? '',
        entityId: json['entity_id'] as String?,
        action: json['action'] as String? ?? '',
        oldData: json['old_data'] is Map
            ? Map<String, dynamic>.from(json['old_data'] as Map)
            : null,
        newData: json['new_data'] is Map
            ? Map<String, dynamic>.from(json['new_data'] as Map)
            : null,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );

  /// Human-friendly one-line description, e.g. "Confirmed meal request".
  String get label {
    final entity = switch (entityType) {
      'meal_request' => 'request',
      'customer' => 'customer',
      'meal_plan' => 'meal plan',
      'customer_meal_plan' => 'plan assignment',
      _ => entityType.replaceAll('_', ' '),
    };
    final verb = switch (action) {
      'confirm' || 'approve' => 'Confirmed',
      'reject' => 'Rejected',
      'complete' => 'Completed',
      'cancel' => 'Cancelled',
      'edit' || 'update' => 'Edited',
      'create' => 'Created',
      'pause' => 'Paused',
      'resume' => 'Resumed',
      'note' => 'Noted on',
      'assign_plan' => 'Assigned plan to',
      'status_change' => 'Changed status of',
      _ => '${action[0].toUpperCase()}${action.substring(1)} —',
    };
    return '$verb $entity';
  }
}
