import 'package:flutter/material.dart';

import '../models/ledger_entry.dart';
import '../models/payment.dart';
import '../models/student.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';
import 'customer_ledger_screen.dart';
import 'monthly_bills_screen.dart';

/// Student ledger: manual payment/due/adjustment/note entries with search,
/// type filter, summary totals and add/edit/delete.
class LedgerScreen extends StatefulWidget {
  const LedgerScreen({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<LedgerScreen> createState() => LedgerScreenState();
}

class LedgerScreenState extends State<LedgerScreen> {
  final _search = TextEditingController();
  String _view = 'balances'; // balances | entries
  String _filter = 'all'; // all | payment | due | adjustment | note
  bool _loading = true;
  String? _error;
  List<LedgerEntry> _entries = [];

  bool _balLoading = true;
  String? _balError;
  List<CustomerBalance> _balances = [];

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

  /// Reloads whichever view is currently active (also called on tab switch).
  Future<void> reload() async {
    if (_view == 'balances') return _loadBalances();
    if (mounted) setState(() => _error = null);
    try {
      final entries = await widget.databaseService.fetchLedgerEntries(
        search: _search.text,
        type: _filter,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the ledger.';
        _loading = false;
      });
    }
  }

  Future<void> _loadBalances() async {
    if (mounted) setState(() => _balError = null);
    try {
      final list = await widget.databaseService
          .fetchCustomerBalances(search: _search.text);
      if (!mounted) return;
      setState(() {
        _balances = list;
        _balLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _balError = 'Could not load customer balances.';
        _balLoading = false;
      });
    }
  }

  void _setView(String v) {
    if (v == _view) return;
    setState(() => _view = v);
    reload();
  }

  Future<void> _openCustomer(CustomerBalance b) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerLedgerScreen(
          databaseService: widget.databaseService,
          student: b.student,
        ),
      ),
    );
    // A payment/adjustment may have changed the balance while inside.
    _loadBalances();
  }

  void _setFilter(String f) {
    setState(() => _filter = f);
    reload();
  }

  void _openMonthlyBills() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            MonthlyBillsScreen(databaseService: widget.databaseService),
      ),
    );
  }

  Future<void> _addOrEdit([LedgerEntry? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LedgerSheet(
        databaseService: widget.databaseService,
        existing: existing,
      ),
    );
    if (saved == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(existing == null ? 'Entry added.' : 'Entry updated.')),
        );
      }
      reload();
    }
  }

  Future<void> _delete(LedgerEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text('Delete this ${e.entryTypeLabel.toLowerCase()} entry'
            '${e.studentName.isEmpty ? '' : ' for ${e.studentName}'}?'),
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
      await widget.databaseService.deleteLedgerEntry(e.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Entry deleted.')));
      reload();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete entry.')));
    }
  }

  int get _totalPayments => _entries
      .where((e) => e.entryType == 'payment')
      .fold(0, (sum, e) => sum + e.amount);

  int get _totalDues => _entries
      .where((e) => e.entryType == 'due' || e.entryType == 'charge')
      .fold(0, (sum, e) => sum + e.amount);

  @override
  Widget build(BuildContext context) {
    final isEntries = _view == 'entries';
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: isEntries
          ? FloatingActionButton.extended(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.add),
              label: const Text('Add entry'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'balances',
                      label: Text('Balances'),
                      icon: Icon(Icons.people_alt_outlined),
                    ),
                    ButtonSegment(
                      value: 'entries',
                      label: Text('Entries'),
                      icon: Icon(Icons.receipt_long_outlined),
                    ),
                  ],
                  selected: {_view},
                  onSelectionChanged: (s) => _setView(s.first),
                ),
                const SizedBox(height: 12),
                if (!isEntries) ...[
                  Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      onTap: _openMonthlyBills,
                      leading: const CircleAvatar(
                        backgroundColor: Color(0xFFEFF6FF),
                        child: Icon(Icons.receipt_long_outlined,
                            color: Color(0xFF2563EB)),
                      ),
                      title: const Text('Monthly bills',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: const Text('Generate and track monthly bills'),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (isEntries) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _SummaryCard(
                          label: 'Payments',
                          value: '₹$_totalPayments',
                          color: const Color(0xFF16A34A),
                          icon: Icons.south_west,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SummaryCard(
                          label: 'Dues',
                          value: '₹$_totalDues',
                          color: const Color(0xFFDC2626),
                          icon: Icons.north_east,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SummaryCard(
                          label: 'Net',
                          value: '₹${_totalPayments - _totalDues}',
                          color: const Color(0xFF2563EB),
                          icon: Icons.account_balance,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => reload(),
                  decoration: InputDecoration(
                    hintText: isEntries
                        ? 'Search by student name'
                        : 'Search customers by name or phone',
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
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                if (isEntries) ...[
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _chip('All', 'all'),
                        _chip('Payment', 'payment'),
                        _chip('Due', 'due'),
                        _chip('Adjustment', 'adjustment'),
                        _chip('Note', 'note'),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: isEntries ? _buildBody() : _buildBalances()),
        ],
      ),
    );
  }

  Widget _buildBalances() {
    if (_balLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_balError != null) {
      return AppErrorState(message: _balError!, onRetry: _loadBalances);
    }
    if (_balances.isEmpty) {
      return AppEmptyState(
        icon: Icons.people_outline,
        title: 'No customers',
        message: _search.text.isNotEmpty
            ? 'No active or paused customers match this search.'
            : 'Active and paused customers will appear here with their balances.',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadBalances,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: _balances.length,
        itemBuilder: (_, i) => _BalanceTile(
          balance: _balances[i],
          onTap: () => _openCustomer(_balances[i]),
        ),
      ),
    );
  }

  Widget _chip(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == value,
        onSelected: (_) => _setFilter(value),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(message: _error!, onRetry: reload);
    }
    if (_entries.isEmpty) {
      return AppEmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: 'No ledger entries',
        message: _search.text.isNotEmpty || _filter != 'all'
            ? 'No entries match this search or filter.'
            : 'Add a payment or due note to start tracking student balances.',
        action: FilledButton.icon(
          onPressed: () => _addOrEdit(),
          icon: const Icon(Icons.add),
          label: const Text('Add entry'),
        ),
      );
    }

    // Group student-wise, preserving the created_at desc order within a group.
    final groups = <String, List<LedgerEntry>>{};
    for (final e in _entries) {
      final key =
          e.studentName.trim().isEmpty ? 'Unassigned' : e.studentName.trim();
      groups.putIfAbsent(key, () => []).add(e);
    }
    final names = groups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          for (final name in names)
            _StudentGroup(
              name: name,
              entries: groups[name]!,
              onEdit: _addOrEdit,
              onDelete: _delete,
            ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w900)),
            ),
            Text(label,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// One customer row in the Balances view: name, phone and money position.
class _BalanceTile extends StatelessWidget {
  const _BalanceTile({required this.balance, required this.onTap});
  final CustomerBalance balance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final settled = balance.balance == 0;
    final color = settled
        ? const Color(0xFF2563EB)
        : balance.owes
            ? const Color(0xFFDC2626)
            : const Color(0xFF16A34A);
    final trailing = settled
        ? 'Settled'
        : balance.owes
            ? '₹${formatMoney(balance.balance)} due'
            : '₹${formatMoney(balance.balance.abs())} cr';
    final name = balance.student.name;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
        ),
        title: Text(name,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          [
            if (balance.student.phone.isNotEmpty) balance.student.phone,
            'Charges ₹${formatMoney(balance.totalCharges)}',
            'Paid ₹${formatMoney(balance.totalPayments)}',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(trailing,
                style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            if (balance.student.status == 'paused')
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: InfoPill('Paused', color: Color(0xFFB45309)),
              ),
          ],
        ),
      ),
    );
  }
}

class _StudentGroup extends StatelessWidget {
  const _StudentGroup({
    required this.name,
    required this.entries,
    required this.onEdit,
    required this.onDelete,
  });
  final String name;
  final List<LedgerEntry> entries;
  final ValueChanged<LedgerEntry> onEdit;
  final ValueChanged<LedgerEntry> onDelete;

  @override
  Widget build(BuildContext context) {
    final net = entries.fold(0, (sum, e) => sum + e.signedBalanceImpact);
    final owes = net < 0; // payments < dues => student owes
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  child: Text(name[0].toUpperCase()),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                Text(
                  owes ? '₹${-net} due' : '₹$net',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: owes
                        ? const Color(0xFFDC2626)
                        : const Color(0xFF16A34A),
                  ),
                ),
              ],
            ),
            const Divider(height: 18),
            for (final e in entries)
              _EntryRow(entry: e, onEdit: onEdit, onDelete: onDelete),
          ],
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });
  final LedgerEntry entry;
  final ValueChanged<LedgerEntry> onEdit;
  final ValueChanged<LedgerEntry> onDelete;

  Color get _color {
    switch (entry.entryType) {
      case 'payment':
        return const Color(0xFF16A34A);
      case 'due':
      case 'charge':
        return const Color(0xFFDC2626);
      case 'adjustment':
        return const Color(0xFF2563EB);
      default:
        return const Color(0xFF334155);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showAmount = entry.amount != 0 || entry.entryType != 'note';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoPill(entry.entryTypeLabel, color: _color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.note.isNotEmpty)
                  Text(entry.note,
                      maxLines: 3, overflow: TextOverflow.ellipsis),
                Row(
                  children: [
                    if (entry.fromRequest) ...[
                      const Icon(Icons.link,
                          size: 12, color: Color(0xFF2563EB)),
                      const SizedBox(width: 3),
                      const Text('From request · ',
                          style: TextStyle(
                              color: Color(0xFF2563EB), fontSize: 11)),
                    ],
                    Text(
                      relativeTime(entry.createdAt),
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (showAmount)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text('₹${entry.amount}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: _color)),
            ),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'edit' ? onEdit(entry) : onDelete(entry),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Add/edit sheet for a ledger entry.
class _LedgerSheet extends StatefulWidget {
  const _LedgerSheet({required this.databaseService, this.existing});
  final DatabaseService databaseService;
  final LedgerEntry? existing;

  @override
  State<_LedgerSheet> createState() => _LedgerSheetState();
}

class _LedgerSheetState extends State<_LedgerSheet> {
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late String _type;
  bool _saving = false;
  String? _error;

  /// Set when the owner taps a suggestion, so we save against the canonical
  /// student id instead of resolving by name. Cleared when they edit the name.
  String? _selectedStudentId;
  List<StudentCandidate> _suggestions = [];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.studentName ?? '');
    _amount = TextEditingController(
        text: (e == null || e.amount == 0) ? '' : '${e.amount}');
    _note = TextEditingController(text: e?.note ?? '');
    _type = e?.entryType ?? 'payment';
    if (!LedgerVocab.entryTypes.contains(_type)) _type = 'payment';
    _selectedStudentId = e?.studentId;
  }

  Future<void> _searchStudents(String value) async {
    final q = value.trim();
    if (q.length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    try {
      final matches = await widget.databaseService.findStudentMatches(q);
      if (!mounted) return;
      setState(() => _suggestions = matches);
    } catch (_) {
      // Suggestions are best-effort; ignore lookup failures.
    }
  }

  void _pickSuggestion(StudentCandidate c) {
    setState(() {
      _name.text = c.student.name;
      _selectedStudentId = c.student.id;
      _suggestions = [];
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a student name.');
      return;
    }
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (amount < 0) {
      setState(() => _error = 'Amount cannot be negative.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.existing == null) {
        await widget.databaseService.createLedgerEntry(
          studentName: name,
          entryType: _type,
          amount: amount,
          note: _note.text,
          studentId: _selectedStudentId,
        );
      } else {
        final e = widget.existing!
          ..studentName = name
          ..entryType = _type
          ..amount = amount
          ..note = _note.text.trim();
        await widget.databaseService.updateLedgerEntry(e);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the entry. Please try again.';
        });
      }
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
            Text(widget.existing == null ? 'Add ledger entry' : 'Edit entry',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              onChanged: (v) {
                _selectedStudentId = null; // typing breaks a prior selection
                _searchStudents(v);
              },
              decoration: const InputDecoration(
                labelText: 'Student name',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            if (_selectedStudentId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.link, size: 14, color: Color(0xFF16A34A)),
                    const SizedBox(width: 4),
                    Text('Linked to existing student',
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 12)),
                  ],
                ),
              ),
            if (_suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in _suggestions.take(5))
                    ActionChip(
                      avatar: const Icon(Icons.person, size: 16),
                      label: Text(c.student.name),
                      onPressed: () => _pickSuggestion(c),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text('Tap a name to link this entry to that student.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Entry type'),
              items: LedgerVocab.entryTypes
                  .map((t) => DropdownMenuItem(
                      value: t, child: Text(LedgerVocab.typeLabel(t))))
                  .toList(),
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Amount (₹) — optional for notes',
                prefixIcon: Icon(Icons.currency_rupee),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note',
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
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save entry'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
