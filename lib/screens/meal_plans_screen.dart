import 'package:flutter/material.dart';

import '../models/meal_plan.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';

/// Manage subscription meal plans (templates assigned to customers). Pushed as
/// its own route from Settings.
class MealPlansScreen extends StatefulWidget {
  const MealPlansScreen({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<MealPlansScreen> createState() => _MealPlansScreenState();
}

class _MealPlansScreenState extends State<MealPlansScreen> {
  bool _loading = true;
  String? _error;
  List<MealPlan> _plans = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final plans = await widget.databaseService.fetchMealPlans();
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load meal plans.';
        _loading = false;
      });
    }
  }

  Future<void> _addOrEdit([MealPlan? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MealPlanFormSheet(
        databaseService: widget.databaseService,
        existing: existing,
      ),
    );
    if (saved == true) {
      _toast(existing == null ? 'Meal plan created.' : 'Meal plan updated.');
      await _load();
    }
  }

  Future<void> _toggleActive(MealPlan plan) async {
    try {
      await widget.databaseService
          .updateMealPlan(plan.copyWith(isActive: !plan.isActive));
      await _load();
    } catch (_) {
      _toast('Could not update the plan.');
    }
  }

  Future<void> _delete(MealPlan plan) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete meal plan?'),
        content: Text(
          'Delete "${plan.name}"? Customers currently on it keep their '
          'assignment but it will show as no plan.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.databaseService.deleteMealPlan(plan.id);
      _toast('Meal plan deleted.');
      await _load();
    } catch (_) {
      _toast('Could not delete the plan.');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Meal plans')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: const Text('New plan'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(message: _error!, onRetry: _load);
    }
    if (_plans.isEmpty) {
      return AppEmptyState(
        icon: Icons.restaurant_outlined,
        title: 'No meal plans yet',
        message:
            'Create plans like "Lunch only" or "Full day" to assign to customers.',
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(),
          icon: const Icon(Icons.add),
          label: const Text('New plan'),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        itemCount: _plans.length,
        itemBuilder: (context, i) {
          final p = _plans[i];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(p.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 16)),
                      ),
                      if (!p.isActive) const InfoPill('Inactive'),
                      PopupMenuButton<String>(
                        onSelected: (v) => switch (v) {
                          'edit' => _addOrEdit(p),
                          'toggle' => _toggleActive(p),
                          _ => _delete(p),
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'edit', child: Text('Edit')),
                          PopupMenuItem(
                              value: 'toggle',
                              child: Text(
                                  p.isActive ? 'Mark inactive' : 'Mark active')),
                          const PopupMenuItem(
                              value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(p.mealsSummary,
                      style: TextStyle(color: Colors.grey.shade700)),
                  if (p.monthlyPrice > 0) ...[
                    const SizedBox(height: 6),
                    InfoPill('₹${p.monthlyPrice.toStringAsFixed(0)} / month'),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Add / edit a meal plan. Pops `true` when saved.
class _MealPlanFormSheet extends StatefulWidget {
  const _MealPlanFormSheet({required this.databaseService, this.existing});
  final DatabaseService databaseService;
  final MealPlan? existing;

  @override
  State<_MealPlanFormSheet> createState() => _MealPlanFormSheetState();
}

class _MealPlanFormSheetState extends State<_MealPlanFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _monthly;
  late bool _breakfast;
  late bool _lunch;
  late bool _dinner;
  late bool _active;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _monthly = TextEditingController(
        text: e == null || e.monthlyPrice == 0
            ? ''
            : e.monthlyPrice.toStringAsFixed(0));
    _breakfast = e?.breakfastEnabled ?? false;
    _lunch = e?.lunchEnabled ?? true;
    _dinner = e?.dinnerEnabled ?? true;
    _active = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _monthly.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_breakfast && !_lunch && !_dinner) {
      setState(() => _error = 'Enable at least one meal.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final base = widget.existing ?? const MealPlan(id: '', name: '');
    final plan = base.copyWith(
      name: _name.text.trim(),
      breakfastEnabled: _breakfast,
      lunchEnabled: _lunch,
      dinnerEnabled: _dinner,
      monthlyPrice: num.tryParse(_monthly.text.trim()) ?? 0,
      isActive: _active,
    );
    try {
      if (_isEdit) {
        await widget.databaseService.updateMealPlan(plan);
      } else {
        await widget.databaseService.createMealPlan(plan);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not save the plan. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_isEdit ? 'Edit meal plan' : 'New meal plan',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Plan name',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Breakfast'),
                value: _breakfast,
                onChanged: (v) => setState(() => _breakfast = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Lunch'),
                value: _lunch,
                onChanged: (v) => setState(() => _lunch = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Dinner'),
                value: _dinner,
                onChanged: (v) => setState(() => _dinner = v),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _monthly,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Monthly price (optional)',
                  prefixIcon: Icon(Icons.currency_rupee),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                subtitle: const Text('Available to assign to customers'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isEdit ? 'Save changes' : 'Create plan'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
