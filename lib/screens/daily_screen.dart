import 'package:flutter/material.dart';

import '../models/daily_adjustment.dart';
import '../models/daily_summary.dart';
import '../models/meal_request.dart';
import '../profile/owner_profile.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';

/// "How many lunches and dinners should I prepare for this date?" — base counts
/// from the owner profile, adjusted by approved requests and manual deltas.
class DailyScreen extends StatefulWidget {
  const DailyScreen({
    super.key,
    required this.profile,
    required this.databaseService,
  });

  final OwnerProfile profile;
  final DatabaseService databaseService;

  @override
  State<DailyScreen> createState() => DailyScreenState();
}

class DailyScreenState extends State<DailyScreen> {
  DateTime _date = _today();
  bool _loading = true;
  String? _error;
  DailySummary? _summary;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _weekdays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  String get _dateStr =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  String get _dateHeading {
    final today = _today();
    final diff = _date.difference(today).inDays;
    final label = diff == 0
        ? 'Today'
        : diff == 1
            ? 'Tomorrow'
            : diff == -1
                ? 'Yesterday'
                : _weekdays[_date.weekday - 1];
    return '$label · ${_date.day} ${_months[_date.month - 1]} ${_date.year}';
  }

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(DailyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Base counts changed in Settings: recompute the breakdown.
    if (oldWidget.profile.defaultLunchCount !=
            widget.profile.defaultLunchCount ||
        oldWidget.profile.defaultDinnerCount !=
            widget.profile.defaultDinnerCount) {
      reload();
    }
  }

  /// Public so the shell can refresh when this tab becomes visible.
  Future<void> reload() async {
    if (mounted) setState(() => _error = null);
    try {
      final summary = await widget.databaseService.fetchDailySummary(
        date: _dateStr,
        baseLunch: widget.profile.defaultLunchCount,
        baseDinner: widget.profile.defaultDinnerCount,
      );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the daily count.';
        _loading = false;
      });
    }
  }

  void _shift(int days) {
    setState(() {
      _date = _date.add(Duration(days: days));
      _loading = true;
    });
    reload();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 1),
      lastDate: DateTime(_date.year + 1),
    );
    if (picked != null) {
      setState(() {
        _date = DateTime(picked.year, picked.month, picked.day);
        _loading = true;
      });
      reload();
    }
  }

  Future<void> _addAdjustment() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AdjustmentSheet(
        databaseService: widget.databaseService,
        date: _dateStr,
      ),
    );
    if (saved == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Manual adjustment added.')),
        );
      }
      reload();
    }
  }

  Future<void> _deleteAdjustment(DailyAdjustment a) async {
    try {
      await widget.databaseService.deleteDailyAdjustment(a.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Adjustment removed.')),
      );
      reload();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not remove adjustment.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DateBar(
          heading: _dateHeading,
          onPrev: () => _shift(-1),
          onNext: () => _shift(1),
          onPick: _pickDate,
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
    final s = _summary!;
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: _MealTotal(
                  title: 'Lunch',
                  count: s.finalLunch,
                  icon: Icons.lunch_dining,
                  color: const Color(0xFFEA580C),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MealTotal(
                  title: 'Dinner',
                  count: s.finalDinner,
                  icon: Icons.dinner_dining,
                  color: const Color(0xFF7C3AED),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Breakdown',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Base count from Settings, ± approved request adjustments, '
                  '± manual adjustments for this date.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
                const SizedBox(height: 10),
                _BreakdownTable(label: 'Lunch', s: s, isLunch: true),
                const Divider(height: 22),
                _BreakdownTable(label: 'Dinner', s: s, isLunch: false),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Manual adjustments',
            trailing: TextButton.icon(
              onPressed: _addAdjustment,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
            child: s.adjustments.isEmpty
                ? _emptyLine('No manual adjustments for this date.')
                : Column(
                    children: [
                      for (final a in s.adjustments)
                        _AdjustmentTile(
                          adjustment: a,
                          onDelete: () => _deleteAdjustment(a),
                        ),
                    ],
                  ),
          ),
          if (s.additions.isNotEmpty) ...[
            const SizedBox(height: 16),
            _RequestSection(
              title: 'Added meals',
              icon: Icons.add_circle_outline,
              color: const Color(0xFF16A34A),
              requests: s.additions,
            ),
          ],
          if (s.lunchCancellations.isNotEmpty) ...[
            const SizedBox(height: 16),
            _RequestSection(
              title: 'Lunch cancellations',
              icon: Icons.remove_circle_outline,
              color: const Color(0xFFDC2626),
              requests: s.lunchCancellations,
            ),
          ],
          if (s.dinnerCancellations.isNotEmpty) ...[
            const SizedBox(height: 16),
            _RequestSection(
              title: 'Dinner cancellations',
              icon: Icons.remove_circle_outline,
              color: const Color(0xFFDC2626),
              requests: s.dinnerCancellations,
            ),
          ],
          if (s.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            _RequestSection(
              title: 'Notes (no count change)',
              icon: Icons.sticky_note_2_outlined,
              color: const Color(0xFF334155),
              requests: s.notes,
            ),
          ],
          if (s.needsDateReview.isNotEmpty) ...[
            const SizedBox(height: 16),
            _RequestSection(
              title: 'Approved but not counted — unclear date',
              icon: Icons.event_busy_outlined,
              color: const Color(0xFFD97706),
              requests: s.needsDateReview,
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _emptyLine(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text, style: TextStyle(color: Colors.grey.shade600)),
      );
}

class _DateBar extends StatelessWidget {
  const _DateBar({
    required this.heading,
    required this.onPrev,
    required this.onNext,
    required this.onPick,
  });
  final String heading;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            IconButton(
              onPressed: onPrev,
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous day',
            ),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onPick,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.calendar_today, size: 16),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          heading,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next day',
            ),
          ],
        ),
      ),
    );
  }
}

class _MealTotal extends StatelessWidget {
  const _MealTotal({
    required this.title,
    required this.count,
    required this.icon,
    required this.color,
  });
  final String title;
  final int count;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Icon(icon, size: 34, color: color),
            const SizedBox(height: 8),
            Text('$count',
                style: const TextStyle(
                    fontSize: 46, fontWeight: FontWeight.w900, height: 1)),
            const SizedBox(height: 4),
            Text('$title boxes',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _BreakdownTable extends StatelessWidget {
  const _BreakdownTable({
    required this.label,
    required this.s,
    required this.isLunch,
  });
  final String label;
  final DailySummary s;
  final bool isLunch;

  @override
  Widget build(BuildContext context) {
    final base = isLunch ? s.baseLunch : s.baseDinner;
    final added = isLunch ? s.lunchAdded : s.dinnerAdded;
    final cancelled = isLunch ? s.lunchCancelled : s.dinnerCancelled;
    final manual = isLunch ? s.manualLunch : s.manualDinner;
    final total = isLunch ? s.finalLunch : s.finalDinner;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 6),
        _row('Base count (from Settings)', '$base'),
        _row('Approved additions', added == 0 ? '0' : '+$added'),
        _row('Approved cancellations', cancelled == 0 ? '0' : '-$cancelled'),
        _row('Manual adjustments (this date)',
            manual == 0 ? '0' : (manual > 0 ? '+$manual' : '$manual')),
        const Divider(height: 16),
        _row('Final total', '$total', bold: true),
      ],
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w900 : FontWeight.w500,
      fontSize: bold ? 16 : 14,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: style.copyWith(
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
          Text(value, style: style),
        ],
      ),
    );
  }
}

class _AdjustmentTile extends StatelessWidget {
  const _AdjustmentTile({required this.adjustment, required this.onDelete});
  final DailyAdjustment adjustment;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final positive = adjustment.delta >= 0;
    final color = positive ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          InfoPill('${adjustment.deltaLabel} ${adjustment.mealLabel}',
              color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              adjustment.reason.isEmpty
                  ? 'Manual adjustment'
                  : adjustment.reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _RequestSection extends StatelessWidget {
  const _RequestSection({
    required this.title,
    required this.icon,
    required this.color,
    required this.requests,
  });
  final String title;
  final IconData icon;
  final Color color;
  final List<MealRequest> requests;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: title,
      child: Column(
        children: [
          for (final r in requests)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.studentName,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          '${r.requestTypeLabel}'
                          '${r.mealType == 'none' ? '' : ' · ${r.mealTypeLabel}'}',
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Bottom-sheet form to add a manual lunch/dinner delta for a date.
class _AdjustmentSheet extends StatefulWidget {
  const _AdjustmentSheet({required this.databaseService, required this.date});
  final DatabaseService databaseService;
  final String date;

  @override
  State<_AdjustmentSheet> createState() => _AdjustmentSheetState();
}

class _AdjustmentSheetState extends State<_AdjustmentSheet> {
  int _lunch = 0;
  int _dinner = 0;
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_lunch == 0 && _dinner == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set a lunch or dinner delta first.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.databaseService.createDailyAdjustment(
        date: widget.date,
        lunchDelta: _lunch,
        dinnerDelta: _dinner,
        note: _note.text,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save adjustment.')),
        );
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add manual adjustment',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          _Stepper(
            label: 'Lunch delta',
            value: _lunch,
            onChanged: (v) => setState(() => _lunch = v),
          ),
          const SizedBox(height: 12),
          _Stepper(
            label: 'Dinner delta',
            value: _dinner,
            onChanged: (v) => setState(() => _dinner = v),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              prefixIcon: Icon(Icons.notes_outlined),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save adjustment'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child:
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        IconButton.filledTonal(
          onPressed: () => onChanged(value - 1),
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 48,
          child: Text(
            value > 0 ? '+$value' : '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
        ),
        IconButton.filledTonal(
          onPressed: () => onChanged(value + 1),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}
