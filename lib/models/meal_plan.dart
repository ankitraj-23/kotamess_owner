/// Mirror of a row in `meal_plans` — a named subscription template an owner can
/// assign to customers (e.g. "Lunch + Dinner monthly").
class MealPlan {
  final String id;
  final String name;
  final bool lunchEnabled;
  final bool dinnerEnabled;
  final num monthlyPrice;
  final num lunchPrice;
  final num dinnerPrice;
  final bool isActive;
  final DateTime? createdAt;

  const MealPlan({
    required this.id,
    required this.name,
    this.lunchEnabled = false,
    this.dinnerEnabled = false,
    this.monthlyPrice = 0,
    this.lunchPrice = 0,
    this.dinnerPrice = 0,
    this.isActive = true,
    this.createdAt,
  });

  factory MealPlan.fromJson(Map<String, dynamic> json) => MealPlan(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        lunchEnabled: json['lunch_enabled'] as bool? ?? false,
        dinnerEnabled: json['dinner_enabled'] as bool? ?? false,
        monthlyPrice: (json['monthly_price'] as num?) ?? 0,
        lunchPrice: (json['lunch_price'] as num?) ?? 0,
        dinnerPrice: (json['dinner_price'] as num?) ?? 0,
        isActive: json['is_active'] as bool? ?? true,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );

  /// Owner-writable fields for create/update (id / owner_id / timestamps are
  /// set by the DB or service).
  Map<String, dynamic> toWritable() => {
        'name': name.trim(),
        'lunch_enabled': lunchEnabled,
        'dinner_enabled': dinnerEnabled,
        'monthly_price': monthlyPrice,
        'lunch_price': lunchPrice,
        'dinner_price': dinnerPrice,
        'is_active': isActive,
      };

  MealPlan copyWith({
    String? name,
    bool? lunchEnabled,
    bool? dinnerEnabled,
    num? monthlyPrice,
    num? lunchPrice,
    num? dinnerPrice,
    bool? isActive,
  }) {
    return MealPlan(
      id: id,
      name: name ?? this.name,
      lunchEnabled: lunchEnabled ?? this.lunchEnabled,
      dinnerEnabled: dinnerEnabled ?? this.dinnerEnabled,
      monthlyPrice: monthlyPrice ?? this.monthlyPrice,
      lunchPrice: lunchPrice ?? this.lunchPrice,
      dinnerPrice: dinnerPrice ?? this.dinnerPrice,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
    );
  }

  /// Short "L · D" style summary of the meals this plan includes.
  String get mealsSummary {
    final parts = <String>[
      if (lunchEnabled) 'Lunch',
      if (dinnerEnabled) 'Dinner',
    ];
    return parts.isEmpty ? 'No meals' : parts.join(' · ');
  }
}

/// Mirror of a row in `customer_meal_plans` — a customer's assigned plan over a
/// date range. [plan] is populated when the assignment is fetched with its plan
/// joined in.
class CustomerMealPlan {
  final String id;
  final String studentId;
  final String? mealPlanId;
  final String startDate; // 'YYYY-MM-DD'
  final String? endDate;
  final bool isActive;
  final DateTime? createdAt;
  final MealPlan? plan;

  const CustomerMealPlan({
    required this.id,
    required this.studentId,
    required this.mealPlanId,
    required this.startDate,
    required this.endDate,
    required this.isActive,
    this.createdAt,
    this.plan,
  });

  factory CustomerMealPlan.fromJson(Map<String, dynamic> json) {
    final planJson = json['meal_plans'];
    return CustomerMealPlan(
      id: json['id'] as String,
      studentId: json['student_id'] as String,
      mealPlanId: json['meal_plan_id'] as String?,
      startDate: json['start_date'] as String? ?? '',
      endDate: json['end_date'] as String?,
      isActive: json['is_active'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      plan: planJson is Map
          ? MealPlan.fromJson(Map<String, dynamic>.from(planJson))
          : null,
    );
  }
}
