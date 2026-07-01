import 'package:flutter/material.dart';

import '../models/usage_evidence.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';

/// Full "Usage Evidence" view — proof of real merchant activity for the Week 7
/// submission. This first version shows the same summary metrics as the Home
/// card in a fuller layout; detailed charts and a per-day activity log land in
/// the next step.
class UsageEvidenceScreen extends StatefulWidget {
  const UsageEvidenceScreen({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<UsageEvidenceScreen> createState() => _UsageEvidenceScreenState();
}

class _UsageEvidenceScreenState extends State<UsageEvidenceScreen> {
  static const _accent = Color(0xFF16A34A);

  bool _loading = true;
  String? _error;
  UsageEvidence? _evidence;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final e = await widget.databaseService.fetchUsageEvidence();
      if (!mounted) return;
      setState(() {
        _evidence = e;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load usage.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Usage')),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(message: _error!, onRetry: _load);
    }
    final e = _evidence!;
    // Rolling windows for display, from local "today" — mirrors the backend
    // definition; display only, no calculation change.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final currentRange =
        formatDayRange(today.subtract(const Duration(days: 6)), today);
    final previousRange = formatDayRange(
      today.subtract(const Duration(days: 13)),
      today.subtract(const Duration(days: 7)),
    );
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (e.isEmpty)
            SectionCard(
              child: Row(
                children: [
                  Icon(Icons.insights_outlined, color: Colors.grey.shade400),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No usage yet. Import chats and review requests to build '
                      'your usage.',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            ),
          if (e.isEmpty) const SizedBox(height: 12),
          SectionCard(
            title: 'Active days',
            child: Column(
              children: [
                _periodRow('Current period', currentRange,
                    '${e.activeDaysThisWeek}/7 active'),
                _periodRow('Previous period', previousRange,
                    '${e.activeDaysLastWeek}/7 active'),
                _row('Current streak', '${e.currentStreakDays} days'),
                _row('Last active',
                    e.lastActiveAt == null ? '—' : formatStamp(e.lastActiveAt)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Requests reviewed (last 7 days)',
            child: Column(
              children: [
                _row('Reviewed', '${e.requestsReviewedThisWeek}'),
                _row('Confirmed', '${e.confirmedThisWeek}'),
                _row('Edited', '${e.editedThisWeek}'),
                _row('Rejected', '${e.rejectedThisWeek}'),
                _row('Completed', '${e.completedThisWeek}'),
                _row('Pending now', '${e.pendingNow}'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Imports (last 7 days)',
            child: Column(
              children: [
                _row('Imports', '${e.importsThisWeek}'),
                _row('Messages imported', '${e.messagesImportedThisWeek}'),
                _row('Duplicates skipped', '${e.duplicatesSkippedThisWeek}'),
                _row(
                  'Last import',
                  e.lastImportAt == null
                      ? 'No imports yet'
                      : formatStamp(e.lastImportAt),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            child: Row(
              children: [
                const Icon(Icons.insights_outlined, color: _accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Detailed charts and activity logs will appear here.',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  /// Like [_row] but with a compact date range under the period label.
  Widget _periodRow(String label, String range, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(range,
                    style:
                        TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              ],
            ),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
