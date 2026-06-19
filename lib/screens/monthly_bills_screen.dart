import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ledger_entry.dart';
import '../models/monthly_bill.dart';
import '../models/payment.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';

/// Status → accent colour, shared by the list and detail views.
Color _statusColor(String status) {
  switch (status) {
    case 'paid':
      return const Color(0xFF16A34A);
    case 'partially_paid':
      return const Color(0xFFB45309);
    case 'overdue':
      return const Color(0xFFDC2626);
    default: // unpaid
      return const Color(0xFFDC2626);
  }
}

/// Monthly bills: pick a month, view/generate per-customer bills, drill into a
/// bill for its breakdown and a copyable reminder. Pushed from the Ledger area.
class MonthlyBillsScreen extends StatefulWidget {
  const MonthlyBillsScreen({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<MonthlyBillsScreen> createState() => _MonthlyBillsScreenState();
}

class _MonthlyBillsScreenState extends State<MonthlyBillsScreen> {
  late int _month;
  late int _year;
  bool _loading = true;
  bool _generating = false;
  String? _error;
  List<MonthlyBill> _bills = [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = now.month;
    _year = now.year;
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final bills = await widget.databaseService
          .fetchMonthlyBills(month: _month, year: _year);
      if (!mounted) return;
      setState(() {
        _bills = bills;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load bills for this month.';
        _loading = false;
      });
    }
  }

  void _changeMonth(int delta) {
    var m = _month + delta;
    var y = _year;
    if (m < 1) {
      m = 12;
      y--;
    } else if (m > 12) {
      m = 1;
      y++;
    }
    setState(() {
      _month = m;
      _year = y;
      _loading = true;
    });
    _load();
  }

  Future<void> _pickMonth() async {
    final picked = await showDialog<({int month, int year})>(
      context: context,
      builder: (_) => _MonthPickerDialog(month: _month, year: _year),
    );
    if (picked == null) return;
    setState(() {
      _month = picked.month;
      _year = picked.year;
      _loading = true;
    });
    _load();
  }

  Future<void> _generateAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Generate all bills?'),
        content: Text(
          'This generates (or refreshes) bills for every active and paused '
          'customer for ${MonthlyBillVocab.monthName(_month)} $_year.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Generate')),
        ],
      ),
    );
    if (ok != true) return;
    await _runGeneration(
      () => widget.databaseService
          .generateMonthlyBills(month: _month, year: _year),
      (n) => '$n bill${n == 1 ? '' : 's'} generated.',
    );
  }

  Future<void> _generateOne() async {
    final student = await showModalBottomSheet<({String id, String name})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CustomerPickerSheet(databaseService: widget.databaseService),
    );
    if (student == null) return;
    await _runGeneration(
      () => widget.databaseService.generateMonthlyBills(
          month: _month, year: _year, studentId: student.id),
      (_) => 'Bill generated for ${student.name}.',
    );
  }

  /// Runs a generation call with a loading flag, a success SnackBar and reload.
  Future<void> _runGeneration(
    Future<List<MonthlyBill>> Function() run,
    String Function(int count) message,
  ) async {
    setState(() => _generating = true);
    try {
      final saved = await run();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message(saved.length))));
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not generate bills.')));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _openBill(MonthlyBill bill) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MonthlyBillDetailScreen(
          databaseService: widget.databaseService,
          bill: bill,
        ),
      ),
    );
  }

  num get _totalBilled => _bills.fold<num>(0, (s, b) => s + b.grossBill);
  num get _totalPending => _bills.fold<num>(0, (s, b) => s + b.pending);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Monthly bills')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              children: [
                _MonthSelector(
                  label: '${MonthlyBillVocab.monthName(_month)} $_year',
                  onPrev: _generating ? null : () => _changeMonth(-1),
                  onNext: _generating ? null : () => _changeMonth(1),
                  onTapLabel: _generating ? null : _pickMonth,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _generating ? null : _generateAll,
                        icon: _generating
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_awesome),
                        label: const Text('Generate all'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _generating ? null : _generateOne,
                        icon: const Icon(Icons.person_add_alt),
                        label: const Text('One customer'),
                      ),
                    ),
                  ],
                ),
                if (!_loading && _error == null && _bills.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          label: 'Bills',
                          value: '${_bills.length}',
                          color: const Color(0xFF2563EB),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatCard(
                          label: 'Billed',
                          value: '₹${formatMoney(_totalBilled)}',
                          color: const Color(0xFF334155),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatCard(
                          label: 'Pending',
                          value: '₹${formatMoney(_totalPending)}',
                          color: const Color(0xFFDC2626),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 4),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(message: _error!, onRetry: _load);
    }
    if (_bills.isEmpty) {
      return AppEmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'No bills yet',
        message:
            'No bills for ${MonthlyBillVocab.monthName(_month)} $_year. '
            'Tap “Generate all” to create them for active and paused customers.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: _bills.length,
        itemBuilder: (_, i) =>
            _BillTile(bill: _bills[i], onTap: () => _openBill(_bills[i])),
      ),
    );
  }
}

class _MonthSelector extends StatelessWidget {
  const _MonthSelector({
    required this.label,
    required this.onPrev,
    required this.onNext,
    required this.onTapLabel,
  });
  final String label;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onTapLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            IconButton(
                onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: InkWell(
                onTap: onTapLabel,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.event, size: 18),
                      const SizedBox(width: 8),
                      Text(label,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
                onPressed: onNext, icon: const Icon(Icons.chevron_right)),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w900, color: color)),
            ),
            Text(label,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _BillTile extends StatelessWidget {
  const _BillTile({required this.bill, required this.onTap});
  final MonthlyBill bill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(bill.status);
    final name = bill.studentName.trim().isEmpty ? '—' : bill.studentName;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          child: Text(name == '—' ? '?' : name[0].toUpperCase()),
        ),
        title: Text(name,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          'Base ₹${formatMoney(bill.baseAmount)} · '
          'Extra ₹${formatMoney(bill.extraAmount)} · '
          'Paid ₹${formatMoney(bill.paidAmount)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('₹${formatMoney(bill.pending)}',
                style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 4),
            InfoPill(bill.statusLabel, color: color),
          ],
        ),
      ),
    );
  }
}

/// Year stepper + 12-month grid for picking a billing period.
class _MonthPickerDialog extends StatefulWidget {
  const _MonthPickerDialog({required this.month, required this.year});
  final int month;
  final int year;

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _year = widget.year;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
              onPressed: () => setState(() => _year--),
              icon: const Icon(Icons.chevron_left)),
          Text('$_year',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          IconButton(
              onPressed: () => setState(() => _year++),
              icon: const Icon(Icons.chevron_right)),
        ],
      ),
      content: SizedBox(
        width: 300,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var m = 1; m <= 12; m++)
              ChoiceChip(
                label: Text(MonthlyBillVocab.months[m - 1].substring(0, 3)),
                selected: m == widget.month && _year == widget.year,
                onSelected: (_) =>
                    Navigator.pop(context, (month: m, year: _year)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
      ],
    );
  }
}

/// Picks one active/paused customer to generate a single bill for.
class _CustomerPickerSheet extends StatefulWidget {
  const _CustomerPickerSheet({required this.databaseService});
  final DatabaseService databaseService;

  @override
  State<_CustomerPickerSheet> createState() => _CustomerPickerSheetState();
}

class _CustomerPickerSheetState extends State<_CustomerPickerSheet> {
  bool _loading = true;
  String? _error;
  List<({String id, String name, String phone})> _customers = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final balances = await widget.databaseService.fetchCustomerBalances();
      if (!mounted) return;
      setState(() {
        _customers = balances
            .map((b) =>
                (id: b.student.id, name: b.student.name, phone: b.student.phone))
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load customers.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Generate bill for…',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(message: _error!, onRetry: _load);
    }
    if (_customers.isEmpty) {
      return const AppEmptyState(
        icon: Icons.people_outline,
        title: 'No customers',
        message: 'Active and paused customers will appear here.',
      );
    }
    return ListView.builder(
      itemCount: _customers.length,
      itemBuilder: (_, i) {
        final c = _customers[i];
        return ListTile(
          leading: CircleAvatar(
            child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase()),
          ),
          title: Text(c.name),
          subtitle: c.phone.isEmpty ? null : Text(c.phone),
          onTap: () => Navigator.pop(context, (id: c.id, name: c.name)),
        );
      },
    );
  }
}

/// Detail for one bill: breakdown, the month's ledger entries + payments, and a
/// copyable reminder message.
class MonthlyBillDetailScreen extends StatefulWidget {
  const MonthlyBillDetailScreen({
    super.key,
    required this.databaseService,
    required this.bill,
  });

  final DatabaseService databaseService;
  final MonthlyBill bill;

  @override
  State<MonthlyBillDetailScreen> createState() =>
      _MonthlyBillDetailScreenState();
}

class _MonthlyBillDetailScreenState extends State<MonthlyBillDetailScreen> {
  bool _loading = true;
  String? _error;
  List<LedgerEntry> _entries = [];
  List<Payment> _payments = [];

  MonthlyBill get _bill => widget.bill;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final b = await widget.databaseService.fetchBillBreakdown(
        studentId: _bill.studentId,
        month: _bill.billMonth,
        year: _bill.billYear,
      );
      if (!mounted) return;
      setState(() {
        _entries = b.entries;
        _payments = b.payments;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the bill breakdown.';
        _loading = false;
      });
    }
  }

  Future<void> _copyMessage() async {
    await Clipboard.setData(ClipboardData(text: _bill.reminderMessage()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Message copied.')));
  }

  @override
  Widget build(BuildContext context) {
    final name = _bill.studentName.trim().isEmpty ? 'Bill' : _bill.studentName;
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _copyMessage,
        icon: const Icon(Icons.copy),
        label: const Text('Copy message'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final color = _statusColor(_bill.status);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        // Header: period, phone, pending + status.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_bill.periodLabel,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                if (_bill.studentPhone.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.phone,
                          size: 14, color: Color(0xFF64748B)),
                      const SizedBox(width: 6),
                      Text(_bill.studentPhone,
                          style: const TextStyle(color: Color(0xFF64748B))),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Pending',
                              style: TextStyle(
                                  color: Colors.grey.shade600, fontSize: 13)),
                          Text('₹${formatMoney(_bill.pending)}',
                              style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w900,
                                  color: color)),
                        ],
                      ),
                    ),
                    InfoPill(_bill.statusLabel, color: color),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Calculation breakdown.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _BreakdownRow('Base (plan)', _bill.baseAmount),
                _BreakdownRow('Extra charges', _bill.extraAmount),
                _BreakdownRow('Adjustments', _bill.adjustmentAmount),
                _BreakdownRow('Credits', -_bill.creditAmount),
                _BreakdownRow('Paid', -_bill.paidAmount,
                    color: const Color(0xFF16A34A)),
                const Divider(height: 20),
                _BreakdownRow('Final pending', _bill.finalAmount,
                    bold: true, color: color),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        _SectionTitle('Payments this month', count: _payments.length),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          AppErrorState(message: _error!, onRetry: _load)
        else ...[
          if (_payments.isEmpty)
            _muted('No payments recorded this month.')
          else
            for (final p in _payments) _PaymentRow(payment: p),
          const SizedBox(height: 20),
          _SectionTitle('Ledger entries this month', count: _entries.length),
          if (_entries.isEmpty)
            _muted('No ledger entries this month.')
          else
            for (final e in _entries) _LedgerRow(entry: e),
        ],
      ],
    );
  }

  Widget _muted(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: TextStyle(color: Colors.grey.shade500)),
      );
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow(this.label, this.amount, {this.bold = false, this.color});
  final String label;
  final num amount;
  final bool bold;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final sign = amount < 0 ? '-' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
          Text('$sign₹${formatMoney(amount.abs())}',
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
                  color: color)),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('$title ($count)',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.payment});
  final Payment payment;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFDCFCE7),
          child: Icon(Icons.south_west, color: Color(0xFF16A34A), size: 20),
        ),
        title: Text('₹${formatMoney(payment.amount)}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          [
            payment.paymentDate,
            if (payment.paymentMode != null) payment.modeLabel,
            if (payment.note.isNotEmpty) payment.note,
          ].join(' · '),
        ),
        trailing: InfoPill(payment.modeLabel, color: const Color(0xFF16A34A)),
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});
  final LedgerEntry entry;

  Color get _color {
    switch (entry.entryType) {
      case 'payment':
        return const Color(0xFF16A34A);
      case 'due':
      case 'charge':
        return const Color(0xFFDC2626);
      case 'adjustment':
      case 'manual_adjustment':
        return const Color(0xFF2563EB);
      default:
        return const Color(0xFF334155);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showAmount = entry.amount != 0 || entry.entryType != 'note';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                  Text(entry.entryDate,
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                ],
              ),
            ),
            if (showAmount)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Text('₹${entry.amount}',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, color: _color)),
              ),
          ],
        ),
      ),
    );
  }
}
