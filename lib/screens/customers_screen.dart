import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/student.dart';
import '../services/database_service.dart';
import '../services/student_roster_import_service.dart';
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
  bool _importing = false;
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

  /// Lets the owner pick a CSV roster export, imports it, then shows a summary
  /// and refreshes the list. Existing customers are updated and new ones added;
  /// nobody is deleted (see [DatabaseService.importStudentRoster]).
  Future<void> _importCsv() async {
    final FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );
    } catch (_) {
      _toast('Could not open the file picker.');
      return;
    }
    if (picked == null || picked.files.isEmpty) return; // cancelled

    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _toast('Could not read the selected file.');
      return;
    }

    setState(() => _importing = true);
    try {
      // Excel CSV exports are UTF-8 (allowMalformed tolerates a stray BOM/byte).
      final content = utf8.decode(bytes, allowMalformed: true);
      final result = await widget.databaseService.importRosterCsv(content);
      if (!mounted) return;
      await reload();
      if (!mounted) return;
      await _showImportSummary(result);
    } on FormatException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Import failed. Check the file and try again.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _showImportSummary(RosterImportResult result) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import complete'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Created: ${result.created}'),
              Text('Updated: ${result.updated}'),
              Text('Skipped: ${result.skipped}'),
              Text('Ambiguous (needs review): ${result.ambiguous}'),
              if (result.issues.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Rows needing attention:',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final i in result.issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            'Line ${i.lineNumber}'
                            '${i.name.isEmpty ? '' : ' (${i.name})'}: ${i.reason}',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
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
                  OutlinedButton.icon(
                    onPressed: _importing ? null : _importCsv,
                    icon: _importing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_file, size: 18),
                    label: const Text('Import CSV'),
                  ),
                  const SizedBox(width: 8),
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
