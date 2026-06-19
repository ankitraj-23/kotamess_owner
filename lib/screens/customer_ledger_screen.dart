import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ledger_entry.dart';
import '../models/payment.dart';
import '../models/student.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';

/// One customer's ledger: balance summary, received payments and ledger
/// entries, with actions to record a payment or a manual adjustment.
class CustomerLedgerScreen extends StatefulWidget {
  const CustomerLedgerScreen({
    super.key,
    required this.databaseService,
    required this.student,
  });

  final DatabaseService databaseService;
  final Student student;

  @override
  State<CustomerLedgerScreen> createState() => _CustomerLedgerScreenState();
}

class _CustomerLedgerScreenState extends State<CustomerLedgerScreen> {
  bool _loading = true;
  String? _error;
  List<LedgerEntry> _entries = [];
  List<Payment> _payments = [];

  CustomerBalance get _balance =>
      CustomerBalance.from(widget.student, _entries, _payments);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final entries = await widget.databaseService
          .fetchStudentLedgerEntries(widget.student.id);
      final payments =
          await widget.databaseService.fetchPayments(studentId: widget.student.id);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _payments = payments;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this customer’s ledger.';
        _loading = false;
      });
    }
  }

  Future<void> _addPayment() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PaymentSheet(
        databaseService: widget.databaseService,
        student: widget.student,
      ),
    );
    if (ok == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment recorded.')),
        );
      }
      _load();
    }
  }

  Future<void> _addAdjustment() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AdjustmentSheet(
        databaseService: widget.databaseService,
        student: widget.student,
      ),
    );
    if (ok == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Adjustment added.')),
        );
      }
      _load();
    }
  }

  /// Copies the customer's outstanding-balance reminder to the clipboard.
  Future<void> _copyBalanceMessage() async {
    await Clipboard.setData(ClipboardData(text: _balance.reminderMessage()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.student.name),
        actions: [
          IconButton(
            tooltip: 'Copy balance message',
            onPressed: _loading ? null : _copyBalanceMessage,
            icon: const Icon(Icons.copy),
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

    final b = _balance;
    final empty = _entries.isEmpty && _payments.isEmpty;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _BalanceHeader(balance: b, phone: widget.student.phone),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _addPayment,
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text('Add payment'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addAdjustment,
                  icon: const Icon(Icons.tune),
                  label: const Text('Adjustment'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (empty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: AppEmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'Nothing recorded yet',
                message:
                    'Add a payment or an adjustment to start this customer’s ledger.',
              ),
            )
          else ...[
            _SectionTitle('Payments', count: _payments.length),
            if (_payments.isEmpty)
              const _MutedLine('No payments recorded.')
            else
              for (final p in _payments) _PaymentRow(payment: p),
            const SizedBox(height: 20),
            _SectionTitle('Ledger entries', count: _entries.length),
            if (_entries.isEmpty)
              const _MutedLine('No ledger entries.')
            else
              for (final e in _entries) _LedgerRow(entry: e),
          ],
        ],
      ),
    );
  }
}

class _BalanceHeader extends StatelessWidget {
  const _BalanceHeader({required this.balance, required this.phone});
  final CustomerBalance balance;
  final String phone;

  @override
  Widget build(BuildContext context) {
    final owes = balance.owes;
    final settled = balance.balance == 0;
    final color = settled
        ? const Color(0xFF2563EB)
        : owes
            ? const Color(0xFFDC2626)
            : const Color(0xFF16A34A);
    final label = settled
        ? 'Settled'
        : owes
            ? 'Customer owes'
            : 'In credit';
    final amount = formatMoney(balance.balance.abs());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (phone.isNotEmpty) ...[
              Row(
                children: [
                  const Icon(Icons.phone, size: 14, color: Color(0xFF64748B)),
                  const SizedBox(width: 6),
                  Text(phone,
                      style: const TextStyle(color: Color(0xFF64748B))),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text(label,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 2),
            Text('₹$amount',
                style: TextStyle(
                    fontSize: 30, fontWeight: FontWeight.w900, color: color)),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Charges',
                    value: '₹${formatMoney(balance.totalCharges)}',
                    color: const Color(0xFFDC2626),
                  ),
                ),
                Expanded(
                  child: _MiniStat(
                    label: 'Payments',
                    value: '₹${formatMoney(balance.totalPayments)}',
                    color: const Color(0xFF16A34A),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(
      {required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w800, color: color)),
        Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      ],
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

class _MutedLine extends StatelessWidget {
  const _MutedLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(color: Colors.grey.shade500)),
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
                  Text(
                    entry.entryDate,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                  ),
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

/// Bottom sheet to record a received payment into the `payments` table.
class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({required this.databaseService, required this.student});
  final DatabaseService databaseService;
  final Student student;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  DateTime _date = DateTime.now();
  String _mode = 'cash';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final amount = num.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0) {
      setState(() => _error = 'Enter a payment amount greater than 0.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.databaseService.createPayment(
        studentId: widget.student.id,
        amount: amount,
        paymentDate: _ymd(_date),
        paymentMode: _mode,
        note: _note.text,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the payment. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Add payment',
      saving: _saving,
      error: _error,
      onSave: _save,
      children: [
        TextField(
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Amount (₹)',
            prefixIcon: Icon(Icons.currency_rupee),
          ),
        ),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Payment date',
            prefixIcon: Icon(Icons.event),
          ),
          child: InkWell(
            onTap: _pickDate,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_ymd(_date)),
                const Icon(Icons.edit_calendar, size: 18),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _mode,
          decoration: const InputDecoration(
            labelText: 'Payment mode',
            prefixIcon: Icon(Icons.account_balance_wallet_outlined),
          ),
          items: PaymentVocab.modes
              .map((m) => DropdownMenuItem(
                  value: m, child: Text(PaymentVocab.modeLabel(m))))
              .toList(),
          onChanged: (v) => setState(() => _mode = v ?? _mode),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Note (optional)',
            prefixIcon: Icon(Icons.notes_outlined),
          ),
        ),
      ],
    );
  }
}

/// Bottom sheet to add a manual adjustment as a `ledger_entries` row.
class _AdjustmentSheet extends StatefulWidget {
  const _AdjustmentSheet({required this.databaseService, required this.student});
  final DatabaseService databaseService;
  final Student student;

  @override
  State<_AdjustmentSheet> createState() => _AdjustmentSheetState();
}

class _AdjustmentSheetState extends State<_AdjustmentSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  DateTime _date = DateTime.now();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amount.text.trim());
    if (amount == null || amount == 0) {
      setState(() => _error =
          'Enter a non-zero amount (negative gives the customer credit).');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.databaseService.addManualAdjustment(
        studentName: widget.student.name,
        studentId: widget.student.id,
        amount: amount,
        description: _note.text,
        entryDate: _ymd(_date),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the adjustment. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Add adjustment',
      saving: _saving,
      error: _error,
      onSave: _save,
      children: [
        TextField(
          controller: _amount,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(signed: true),
          decoration: const InputDecoration(
            labelText: 'Amount (₹)',
            helperText: 'Positive adds a charge · negative gives credit',
            prefixIcon: Icon(Icons.currency_rupee),
          ),
        ),
        const SizedBox(height: 12),
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Date',
            prefixIcon: Icon(Icons.event),
          ),
          child: InkWell(
            onTap: _pickDate,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_ymd(_date)),
                const Icon(Icons.edit_calendar, size: 18),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Description / note',
            prefixIcon: Icon(Icons.notes_outlined),
          ),
        ),
      ],
    );
  }
}

/// Shared bottom-sheet chrome for the payment/adjustment forms.
class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({
    required this.title,
    required this.saving,
    required this.error,
    required this.onSave,
    required this.children,
  });
  final String title;
  final bool saving;
  final String? error;
  final VoidCallback onSave;
  final List<Widget> children;

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
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            ...children,
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(error!, style: const TextStyle(color: Color(0xFFDC2626))),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: saving ? null : onSave,
                child: saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Formats a date as 'YYYY-MM-DD' to match the DB date columns.
String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
