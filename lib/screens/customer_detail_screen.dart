import 'package:flutter/material.dart';

import '../models/meal_plan.dart';
import '../models/meal_request.dart';
import '../models/student.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';

/// Full customer view: profile, current meal plan (assign / change / end) and
/// request history. Pushed as its own route from the Customers list.
class CustomerDetailScreen extends StatefulWidget {
  const CustomerDetailScreen({
    super.key,
    required this.databaseService,
    required this.customer,
  });

  final DatabaseService databaseService;
  final Student customer;

  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  late Student _customer = widget.customer;
  bool _loading = true;
  String? _error;
  CustomerMealPlan? _activePlan;
  List<MealRequest> _requests = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final plan =
          await widget.databaseService.fetchActiveCustomerPlan(_customer.id);
      final requests =
          await widget.databaseService.fetchCustomerRequests(_customer.id);
      if (!mounted) return;
      setState(() {
        _activePlan = plan;
        _requests = requests;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this customer.';
        _loading = false;
      });
    }
  }

  Future<void> _edit() async {
    final updated = await showModalBottomSheet<Student>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CustomerFormSheet(
        databaseService: widget.databaseService,
        existing: _customer,
      ),
    );
    if (updated != null && mounted) {
      setState(() => _customer = updated);
      _toast('Customer updated.');
    }
  }

  Future<void> _setStatus(String status) async {
    try {
      await widget.databaseService.setCustomerStatus(_customer.id, status);
      if (!mounted) return;
      setState(() => _customer = _customer.copyWith(status: status));
      _toast('Marked ${Student.statusLabel(status).toLowerCase()}.');
    } catch (_) {
      _toast('Could not update status.');
    }
  }

  Future<void> _assignPlan() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssignPlanSheet(
        databaseService: widget.databaseService,
        studentId: _customer.id,
        current: _activePlan,
      ),
    );
    if (changed == true) {
      _toast('Meal plan updated.');
      await _load();
    }
  }

  Future<void> _endPlan() async {
    try {
      await widget.databaseService.endCustomerPlan(_customer.id);
      _toast('Meal plan ended.');
      await _load();
    } catch (_) {
      _toast('Could not end the plan.');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_customer.name),
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _edit,
          ),
          PopupMenuButton<String>(
            tooltip: 'Set status',
            onSelected: _setStatus,
            itemBuilder: (_) => [
              for (final s in Student.statuses)
                if (s != _customer.status)
                  PopupMenuItem(
                      value: s, child: Text('Mark ${Student.statusLabel(s)}')),
            ],
          ),
        ],
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
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ProfileCard(customer: _customer),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Meal plan',
            trailing: TextButton.icon(
              onPressed: _assignPlan,
              icon: const Icon(Icons.tune, size: 18),
              label: Text(_activePlan == null ? 'Assign' : 'Change'),
            ),
            child: _activePlan == null || _activePlan!.plan == null
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('No active meal plan.',
                        style: TextStyle(color: Colors.grey.shade600)),
                  )
                : _PlanRow(
                    assignment: _activePlan!,
                    onEnd: _endPlan,
                  ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Request history',
            child: _requests.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('No requests for this customer yet.',
                        style: TextStyle(color: Colors.grey.shade600)),
                  )
                : Column(
                    children: [
                      for (final r in _requests) _HistoryTile(request: r),
                    ],
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.customer});
  final Student customer;

  @override
  Widget build(BuildContext context) {
    final rows = <(IconData, String)>[
      if (customer.phone.isNotEmpty) (Icons.phone_outlined, customer.phone),
      if (customer.roomOrAddress.isNotEmpty)
        (Icons.home_outlined, customer.roomOrAddress),
      if ((customer.joinedAt ?? '').isNotEmpty)
        (Icons.event_outlined, 'Joined ${customer.joinedAt}'),
      if (customer.notes.isNotEmpty) (Icons.notes_outlined, customer.notes),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  child: Text(customer.name.isEmpty
                      ? '?'
                      : customer.name[0].toUpperCase()),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(customer.name,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800)),
                ),
                CustomerStatusChip(status: customer.status),
              ],
            ),
            if (rows.isNotEmpty) const SizedBox(height: 12),
            for (final (icon, text) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18, color: Colors.grey.shade600),
                    const SizedBox(width: 10),
                    Expanded(child: Text(text)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.assignment, required this.onEnd});
  final CustomerMealPlan assignment;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final plan = assignment.plan!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(plan.name,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 4),
        Text(plan.mealsSummary,
            style: TextStyle(color: Colors.grey.shade700)),
        const SizedBox(height: 6),
        Row(
          children: [
            if (plan.monthlyPrice > 0)
              InfoPill('₹${plan.monthlyPrice.toStringAsFixed(0)} / month'),
            const Spacer(),
            TextButton.icon(
              onPressed: onEnd,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('End plan'),
            ),
          ],
        ),
        Text('Since ${assignment.startDate}',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.request});
  final MealRequest request;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.fact_check_outlined,
              size: 20, color: Colors.grey.shade600),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${request.requestTypeLabel}'
                  '${request.mealType == 'none' ? '' : ' · ${request.mealTypeLabel}'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (request.originalMessage.isNotEmpty)
                  Text('“${request.originalMessage}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 12)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    InfoPill(request.statusLabel),
                    const SizedBox(width: 8),
                    Text(request.dateDisplay,
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Status chip shared by the customers list + detail.
class CustomerStatusChip extends StatelessWidget {
  const CustomerStatusChip({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'active' => const Color(0xFF16A34A),
      'paused' => const Color(0xFFD97706),
      _ => const Color(0xFF64748B),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(Student.statusLabel(status),
          style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.w700)),
    );
  }
}

/// Bottom-sheet to pick / change a customer's active meal plan. Pops `true`
/// when a plan was assigned.
class _AssignPlanSheet extends StatefulWidget {
  const _AssignPlanSheet({
    required this.databaseService,
    required this.studentId,
    required this.current,
  });
  final DatabaseService databaseService;
  final String studentId;
  final CustomerMealPlan? current;

  @override
  State<_AssignPlanSheet> createState() => _AssignPlanSheetState();
}

class _AssignPlanSheetState extends State<_AssignPlanSheet> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<MealPlan> _plans = [];
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.current?.mealPlanId;
    _load();
  }

  Future<void> _load() async {
    try {
      final plans = await widget.databaseService.fetchMealPlans(activeOnly: true);
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load meal plans.';
      });
    }
  }

  Future<void> _save() async {
    final id = _selectedId;
    if (id == null) {
      setState(() => _error = 'Pick a plan first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.databaseService
          .assignMealPlan(studentId: widget.studentId, mealPlanId: id);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not assign the plan. Please try again.';
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Assign meal plan',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_plans.isEmpty)
              Text(
                'No active meal plans yet. Create one from Settings → Meal plans.',
                style: TextStyle(color: Colors.grey.shade600),
              )
            else
              ..._plans.map((p) {
                final selected = _selectedId == p.id;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
                  ),
                  onTap: _busy ? null : () => setState(() => _selectedId = p.id),
                  title: Text(p.name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(p.mealsSummary),
                );
              }),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
            ],
            if (_plans.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save plan'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Add / edit a customer. Returns the created/updated [Student], or null on
/// cancel. Shared by the Customers list and the detail screen.
class CustomerFormSheet extends StatefulWidget {
  const CustomerFormSheet({
    super.key,
    required this.databaseService,
    this.existing,
  });

  final DatabaseService databaseService;
  final Student? existing;

  @override
  State<CustomerFormSheet> createState() => _CustomerFormSheetState();
}

class _CustomerFormSheetState extends State<CustomerFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _room;
  late final TextEditingController _notes;
  late String _status;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _phone = TextEditingController(text: e?.phone ?? '');
    _room = TextEditingController(text: e?.roomOrAddress ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _status = e?.status ?? 'active';
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _room.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Student result;
      if (_isEdit) {
        result = await widget.databaseService.updateCustomer(
          widget.existing!.copyWith(
            name: _name.text.trim(),
            phone: _phone.text.trim(),
            roomOrAddress: _room.text.trim(),
            notes: _notes.text.trim(),
            status: _status,
          ),
        );
      } else {
        result = await widget.databaseService.createCustomer(
          name: _name.text.trim(),
          phone: _phone.text.trim(),
          roomOrAddress: _room.text.trim(),
          notes: _notes.text.trim(),
          status: _status,
        );
      }
      if (mounted) Navigator.pop(context, result);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not save the customer. Please try again.';
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
              Text(_isEdit ? 'Edit customer' : 'Add customer',
                  style:
                      const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _room,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Room / address (optional)',
                  prefixIcon: Icon(Icons.home_outlined),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  prefixIcon: Icon(Icons.toggle_on_outlined),
                ),
                items: Student.statuses
                    .map((s) => DropdownMenuItem(
                        value: s, child: Text(Student.statusLabel(s))))
                    .toList(),
                onChanged: (v) => setState(() => _status = v ?? _status),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  prefixIcon: Icon(Icons.notes_outlined),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isEdit ? 'Save changes' : 'Add customer'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
