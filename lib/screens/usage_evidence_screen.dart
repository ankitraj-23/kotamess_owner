import 'package:flutter/material.dart';

import '../models/usage_evidence.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';

/// Full "Usage" view — Week 7 proof of real merchant activity, built entirely
/// from [UsageEvidence] (which is itself derived from production tables). No
/// internal ids or raw WhatsApp text are ever shown.
class UsageEvidenceScreen extends StatefulWidget {
  const UsageEvidenceScreen({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<UsageEvidenceScreen> createState() => _UsageEvidenceScreenState();
}

class _UsageEvidenceScreenState extends State<UsageEvidenceScreen> {
  static const _accent = Color(0xFF16A34A);
  static const _amber = Color(0xFFD97706);
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

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

  String _shortDate(DateTime d) => '${d.day} ${_months[d.month - 1]}';

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

    if (e.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              child: Row(
                children: [
                  Icon(Icons.insights_outlined, color: Colors.grey.shade400),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Usage will appear after importing chats and reviewing '
                      'requests.',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Rolling windows for display, from local "today" — mirrors the backend
    // definition; display only, no calculation change.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final currentRange =
        '${_shortDate(today.subtract(const Duration(days: 6)))} – ${_shortDate(today)}';
    final previousRange =
        '${_shortDate(today.subtract(const Duration(days: 13)))} – ${_shortDate(today.subtract(const Duration(days: 7)))}';

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _summarySection(e, currentRange, previousRange),
          const SizedBox(height: 12),
          _requirementSection(e),
          const SizedBox(height: 12),
          _heatmapSection(e),
          const SizedBox(height: 12),
          _dailySection(e),
          const SizedBox(height: 12),
          _funnelSection(e),
          const SizedBox(height: 12),
          _impactSection(e),
          const SizedBox(height: 12),
          _activitySection(e),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // --- 1. Top summary -----------------------------------------------------
  Widget _summarySection(
      UsageEvidence e, String currentRange, String previousRange) {
    return SectionCard(
      title: 'Overview',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _metricTile('Current period', currentRange,
                    '${e.activeDaysThisWeek}/7', 'active days'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _metricTile('Previous period', previousRange,
                    '${e.activeDaysLastWeek}/7', 'active days'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _metricTile('Current streak', null,
                    '${e.currentStreakDays}', 'days in a row'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _metricTile(
                  'Last active',
                  null,
                  e.lastActiveAt == null ? 'No activity yet' : 'Active',
                  e.lastActiveAt == null ? '' : formatStamp(e.lastActiveAt),
                  small: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metricTile(String label, String? range, String value, String sub,
      {bool small = false}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          if (range != null)
            Text(range,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontSize: small ? 15 : 22,
                  fontWeight: FontWeight.w900,
                  color: _accent)),
          if (sub.isNotEmpty)
            Text(sub,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
        ],
      ),
    );
  }

  // --- 2. Requirement status ----------------------------------------------
  Widget _requirementSection(UsageEvidence e) {
    final met = e.activeDaysThisWeek >= 5 && e.activeDaysLastWeek >= 5;
    final color = met ? _accent : _amber;
    return SectionCard(
      title: 'Requirement',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(met ? Icons.check_circle : Icons.hourglass_bottom,
                  color: color, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('5+ active days/week × 2 periods',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InfoPill(met ? 'Requirement met' : 'Requirement not met yet',
              color: color),
          const SizedBox(height: 10),
          Text(
            'Active day = chat import or audited owner action such as request '
            'review or customer update.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // --- 3. 14-day heatmap --------------------------------------------------
  Widget _heatmapSection(UsageEvidence e) {
    final days = e.dailyActivity; // oldest -> newest, 14 entries
    final firstWeek = days.length <= 7 ? days : days.sublist(0, 7);
    final secondWeek = days.length <= 7 ? const <UsageDayActivity>[] : days.sublist(7);
    return SectionCard(
      title: 'Last 14 days',
      child: Column(
        children: [
          Row(children: [for (final d in firstWeek) _heatBox(d)]),
          if (secondWeek.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [for (final d in secondWeek) _heatBox(d)]),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _legendSwatch(_accent, 'Active'),
              const SizedBox(width: 14),
              _legendSwatch(Colors.grey.shade200, 'No activity'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heatBox(UsageDayActivity d) {
    const wd = ['', 'M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final active = d.active;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? _accent : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: active ? null : Border.all(color: Colors.grey.shade300),
        ),
        child: Column(
          children: [
            Text(wd[d.date.weekday],
                style: TextStyle(
                    fontSize: 10,
                    color: active ? Colors.white70 : Colors.grey.shade500)),
            const SizedBox(height: 2),
            Text('${d.date.day}',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _legendSwatch(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade300),
          ),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
    );
  }

  // --- 4. Daily activity --------------------------------------------------
  Widget _dailySection(UsageEvidence e) {
    // Newest first reads better as a log.
    final days = e.dailyActivity.reversed.toList();
    return SectionCard(
      title: 'Daily activity',
      child: Column(
        children: [for (final d in days) _dailyRow(d)],
      ),
    );
  }

  Widget _dailyRow(UsageDayActivity d) {
    final date = _shortDate(d.date);
    final parts = <String>[
      if (d.imports > 0) '${d.imports} import${d.imports == 1 ? '' : 's'}',
      if (d.messagesProcessed > 0) '${d.messagesProcessed} msgs',
      if (d.extracted > 0) '${d.extracted} extracted',
      if (d.reviewed > 0) '${d.reviewed} reviewed',
      if (d.duplicatesSkipped > 0) '${d.duplicatesSkipped} dup',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(date,
                style: TextStyle(
                    fontWeight: d.active ? FontWeight.w700 : FontWeight.w500,
                    color: d.active ? null : Colors.grey.shade500)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              d.active ? parts.join(' · ') : 'No activity',
              style: TextStyle(
                  fontSize: 12,
                  color: d.active ? Colors.grey.shade700 : Colors.grey.shade400),
            ),
          ),
        ],
      ),
    );
  }

  // --- 5. Review funnel ---------------------------------------------------
  Widget _funnelSection(UsageEvidence e) {
    final rows = <(String, int)>[
      ('Extracted', e.extractedThisWeek),
      ('Confirmed', e.confirmedThisWeek),
      ('Edited', e.editedThisWeek),
      ('Rejected', e.rejectedThisWeek),
      ('Completed', e.completedThisWeek),
      ('Pending now', e.pendingNow),
    ];
    final max = rows.fold<int>(0, (m, r) => r.$2 > m ? r.$2 : m);
    return SectionCard(
      title: 'Review funnel (current period)',
      child: Column(
        children: [
          for (final r in rows) _funnelRow(r.$1, r.$2, max),
        ],
      ),
    );
  }

  Widget _funnelRow(String label, int value, int max) {
    final frac = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Text('$value',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              height: 8,
              width: double.infinity,
              color: Colors.grey.shade200,
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: frac,
                child: Container(color: _accent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- 6. Impact ----------------------------------------------------------
  Widget _impactSection(UsageEvidence e) {
    return SectionCard(
      title: 'Impact this period',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _impactTile(Icons.fact_check_outlined,
                    '${e.requestsReviewedThisWeek}', 'Requests reviewed'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _impactTile(Icons.forum_outlined,
                    '${e.messagesImportedThisWeek}', 'Messages processed'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _impactTile(Icons.upload_file, '${e.importsThisWeek}',
                    'Imports completed'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _impactTile(Icons.copy_all_outlined,
                    '${e.duplicatesSkippedThisWeek}', 'Duplicates skipped'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _impactTile(IconData icon, String value, String label) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _accent, size: 20),
          const SizedBox(height: 8),
          Text(value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          Text(label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
        ],
      ),
    );
  }

  // --- 7. Recent activity -------------------------------------------------
  Widget _activitySection(UsageEvidence e) {
    final items = e.recentActivity.take(10).toList();
    return SectionCard(
      title: 'Recent activity',
      child: items.isEmpty
          ? Row(
              children: [
                Icon(Icons.inbox_outlined, color: Colors.grey.shade400),
                const SizedBox(width: 12),
                Text('No recent activity yet.',
                    style: TextStyle(color: Colors.grey.shade600)),
              ],
            )
          : Column(children: [for (final it in items) _activityTile(it)]),
    );
  }

  Widget _activityTile(UsageEvidenceActivityItem it) {
    final (icon, color) = it.kind == 'import'
        ? (Icons.upload_file, const Color(0xFF2563EB))
        : (Icons.fact_check_outlined, _accent);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(it.title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(it.subtitle,
                    style:
                        TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              ],
            ),
          ),
          Text(relativeTime(it.timestamp),
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
        ],
      ),
    );
  }
}
