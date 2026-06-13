import 'package:flutter/material.dart';

import '../models/student.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';
import 'customer_detail_screen.dart';

/// Customer (subscriber) management: list, search, filter by status, add/edit,
/// quick status change, and drill into a detail view with plan + history.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<CustomersScreen> createState() => CustomersScreenState();
}

class CustomersScreenState extends State<CustomersScreen> {
  final _search = TextEditingController();

  String _filter = 'all'; // all | active | paused | inactive
  bool _loading = true;
  String? _error;
  List<Student> _items = [];

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Public so the shell can refresh when the tab becomes visible.
  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.databaseService.fetchCustomers(
        status: _filter,
        search: _search.text,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load customers. Pull to refresh.';
        _loading = false;
      });
    }
  }

  void _setFilter(String filter) {
    setState(() => _filter = filter);
    reload();
  }

  Future<void> _add() async {
    final created = await showModalBottomSheet<Student>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          CustomerFormSheet(databaseService: widget.databaseService),
    );
    if (created != null) {
      _toast('Customer added.');
      await reload();
    }
  }

  Future<void> _edit(Student customer) async {
    final updated = await showModalBottomSheet<Student>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CustomerFormSheet(
        databaseService: widget.databaseService,
        existing: customer,
      ),
    );
    if (updated != null) {
      _toast('Customer updated.');
      await reload();
    }
  }

  Future<void> _setStatus(Student customer, String status) async {
    try {
      await widget.databaseService.setCustomerStatus(customer.id, status);
      _toast('Marked ${Student.statusLabel(status).toLowerCase()}.');
      await reload();
    } catch (_) {
      _toast('Could not update status.');
    }
  }

  Future<void> _openDetail(Student customer) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerDetailScreen(
          databaseService: widget.databaseService,
          customer: customer,
        ),
      ),
    );
    // Detail can change status/plan; refresh the list on return.
    if (mounted) reload();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Customers',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  FilledButton.icon(
                    onPressed: _add,
                    icon: const Icon(Icons.person_add_alt_1, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('All', 'all'),
                    _filterChip('Active', 'active'),
                    _filterChip('Paused', 'paused'),
                    _filterChip('Inactive', 'inactive'),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => reload(),
                decoration: InputDecoration(
                  hintText: 'Search by name or phone',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _search.clear();
                            reload();
                          },
                        ),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(message: _error!, onRetry: reload);
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: reload,
        child: ListView(
          children: [
            const SizedBox(height: 80),
            AppEmptyState(
              icon: Icons.groups_outlined,
              title: 'No customers yet',
              message: _filter == 'all'
                  ? 'Add your first subscriber to start tracking meals.'
                  : 'No $_filter customers. Try another filter.',
              action: _filter == 'all'
                  ? FilledButton.icon(
                      onPressed: _add,
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Add customer'),
                    )
                  : null,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        itemBuilder: (context, i) => _CustomerCard(
          customer: _items[i],
          onTap: () => _openDetail(_items[i]),
          onEdit: () => _edit(_items[i]),
          onSetStatus: (s) => _setStatus(_items[i], s),
        ),
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == value,
        onSelected: (_) => _setFilter(value),
      ),
    );
  }
}

class _CustomerCard extends StatelessWidget {
  const _CustomerCard({
    required this.customer,
    required this.onTap,
    required this.onEdit,
    required this.onSetStatus,
  });

  final Student customer;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final ValueChanged<String> onSetStatus;

  @override
  Widget build(BuildContext context) {
    final subtitleParts = <String>[
      if (customer.phone.isNotEmpty) customer.phone,
      if (customer.roomOrAddress.isNotEmpty) customer.roomOrAddress,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                child: Text(customer.name.isEmpty
                    ? '?'
                    : customer.name[0].toUpperCase()),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(customer.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16)),
                    if (subtitleParts.isNotEmpty)
                      Text(subtitleParts.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 13)),
                  ],
                ),
              ),
              CustomerStatusChip(status: customer.status),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') {
                    onEdit();
                  } else {
                    onSetStatus(v);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  for (final s in Student.statuses)
                    if (s != customer.status)
                      PopupMenuItem(
                          value: s,
                          child: Text('Mark ${Student.statusLabel(s)}')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
