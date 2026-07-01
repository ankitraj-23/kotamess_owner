import 'package:flutter/material.dart';

import '../models/dashboard.dart';
import '../models/kitchen_summary.dart';
import '../models/usage_evidence.dart';
import '../profile/owner_profile.dart';
import '../services/database_service.dart';
import '../services/recent_activity_prefs.dart';
import '../widgets/common.dart';
import 'usage_evidence_screen.dart';

/// Owner dashboard: greeting, today's & tomorrow's kitchen summary, key
/// tallies, quick actions and a recent-activity feed. All figures are live
/// from Supabase.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.profile,
    required this.databaseService,
    required this.onOpenCustomers,
    required this.onOpenImport,
    required this.onOpenRequests,
    required this.onOpenDaily,
    required this.onOpenLedger,
  });

  final OwnerProfile profile;
  final DatabaseService databaseService;
  final VoidCallback onOpenCustomers;
  final VoidCallback onOpenImport;
  final VoidCallback onOpenRequests;
  final VoidCallback onOpenDaily;
  final VoidCallback onOpenLedger;

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  final _recentActivityPrefs = RecentActivityPrefs();

  bool _loading = true;
  String? _error;
  DashboardSummary? _summary;

  /// Items at/older than this are hidden from the Home feed only. Loaded from
  /// local prefs; null means "show everything".
  DateTime? _activityClearedAt;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Public so the shell can refresh after imports/approvals.
  Future<void> reload() async {
    if (mounted) setState(() => _error = null);
    try {
      final clearedAt = await _recentActivityPrefs.clearedAt(widget.profile.id);
      final summary = await widget.databaseService.fetchDashboardSummary();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _activityClearedAt = clearedAt;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your dashboard.';
        _loading = false;
      });
    }
  }

  /// Recent-activity items still visible after applying the local cleared-at
  /// cutoff. Items without a timestamp are kept until a cutoff exists.
  List<ActivityItem> _visibleActivity(DashboardSummary s) {
    final cutoff = _activityClearedAt;
    if (cutoff == null) return s.recentActivity;
    return s.recentActivity
        .where((a) => a.timestamp != null && a.timestamp!.isAfter(cutoff))
        .toList();
  }

  /// Hides current Home activity by recording a local cutoff timestamp. Does
  /// NOT delete any requests, imports or ledger data.
  Future<void> _clearRecentActivity() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear recent activity?'),
        content: const Text(
          'This only clears the Home activity feed. Your requests and ledger '
          'data will remain saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _recentActivityPrefs.clearNow(widget.profile.id);
    if (!mounted) return;
    await reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Recent activity cleared from Home.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(message: _error!, onRetry: reload);
    }
    final s = _summary!;
    final activity = _visibleActivity(s);
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Greeting(profile: widget.profile),
          const SizedBox(height: 16),
          _KitchenCard(title: "Today's kitchen", summary: s.today),
          const SizedBox(height: 12),
          // Tomorrow's kitchen was here; replaced by the Usage Evidence card.
          // The tomorrow count (s.tomorrow) is still computed in the backend
          // and remains available for other screens.
          _UsageEvidenceCard(databaseService: widget.databaseService),
          const SizedBox(height: 16),
          _StatsGrid(summary: s),
          const SizedBox(height: 16),
          Text('Quick actions',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          _QuickActions(
            onOpenCustomers: widget.onOpenCustomers,
            onOpenImport: widget.onOpenImport,
            onOpenRequests: widget.onOpenRequests,
            onOpenDaily: widget.onOpenDaily,
            onOpenLedger: widget.onOpenLedger,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Recent activity',
            trailing: activity.isEmpty
                ? null
                : TextButton.icon(
                    onPressed: _clearRecentActivity,
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: const Text('Clear'),
                  ),
            child: activity.isEmpty
                ? const _EmptyActivity()
                : Column(
                    children: [
                      for (final item in activity) _ActivityTile(item: item),
                    ],
                  ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Compact proof-of-usage summary shown on Home in place of the old
/// "Tomorrow's kitchen" card. Loads its own data once (not on every Home
/// rebuild) so a slow/failed evidence fetch never blocks the dashboard, and
/// opens the full [UsageEvidenceScreen] on tap.
class _UsageEvidenceCard extends StatefulWidget {
  const _UsageEvidenceCard({required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<_UsageEvidenceCard> createState() => _UsageEvidenceCardState();
}

class _UsageEvidenceCardState extends State<_UsageEvidenceCard> {
  static const _accent = Color(0xFF16A34A);

  bool _loading = true;
  bool _failed = false;
  UsageEvidence? _evidence;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
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
        _failed = true;
        _loading = false;
      });
    }
  }

  void _openFull() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            UsageEvidenceScreen(databaseService: widget.databaseService),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SectionCard(
        title: 'Usage',
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Loading usage…'),
          ],
        ),
      );
    }
    final e = _evidence;
    if (_failed || e == null) {
      return SectionCard(
        title: 'Usage',
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 20, color: Colors.grey.shade500),
            const SizedBox(width: 10),
            const Expanded(child: Text('Usage unavailable')),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: _openFull,
      child: SectionCard(
        title: 'Usage',
        trailing: const Icon(Icons.chevron_right, color: _accent),
        child: e.isEmpty ? _empty() : _content(e),
      ),
    );
  }

  Widget _empty() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.insights_outlined, color: Colors.grey.shade400),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'No usage yet. Import chats and review requests to build your '
                'usage.',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _openFull,
            child: const Text('View usage'),
          ),
        ),
      ],
    );
  }

  Widget _content(UsageEvidence e) {
    // Rolling windows, computed in the UI from local "today" — mirrors the
    // backend definition (current = today + previous 6 days; previous = the 7
    // days before that). Display only; no calculation change.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final currentStart = today.subtract(const Duration(days: 6));
    final previousStart = today.subtract(const Duration(days: 13));
    final previousEnd = today.subtract(const Duration(days: 7));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _metric(
                'Current period',
                formatDayRange(currentStart, today),
                '${e.activeDaysThisWeek}/7',
                'active days',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _metric(
                'Previous period',
                formatDayRange(previousStart, previousEnd),
                '${e.activeDaysLastWeek}/7',
                'active days',
              ),
            ),
          ],
        ),
        const Divider(height: 20),
        _line(Icons.fact_check_outlined, 'Requests reviewed',
            '${e.requestsReviewedThisWeek}'),
        const SizedBox(height: 8),
        _line(
          Icons.upload_file,
          'Last import',
          e.lastImportAt == null ? 'No imports yet' : formatStamp(e.lastImportAt),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _openFull,
            child: const Text('View usage'),
          ),
        ),
      ],
    );
  }

  Widget _metric(String label, String range, String value, String sub) {
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
          Text(range,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w900, color: _accent)),
          Text(sub,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey.shade600),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13)),
        ),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      ],
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.profile});
  final OwnerProfile profile;

  String get _hello {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final owner = profile.ownerName.isEmpty ? 'Owner' : profile.ownerName;
    final mess = profile.messName.isEmpty ? 'your mess' : profile.messName;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF15803D), Color(0xFF0D9488)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$_hello, $owner',
              style: const TextStyle(
                  color: Colors.white70, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(mess,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text(
            'Here is today’s kitchen plan and what needs your attention.',
            style: TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

/// Today's / tomorrow's "how much to cook" card: lunch and dinner each shown
/// as expected − cancelled + extra = final.
class _KitchenCard extends StatelessWidget {
  const _KitchenCard({required this.title, required this.summary});
  final String title;
  final KitchenSummary summary;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MealLine(
            label: 'Lunch',
            icon: Icons.lunch_dining,
            color: const Color(0xFFEA580C),
            count: summary.lunch,
          ),
          const Divider(height: 18),
          _MealLine(
            label: 'Dinner',
            icon: Icons.dinner_dining,
            color: const Color(0xFF7C3AED),
            count: summary.dinner,
          ),
          const SizedBox(height: 8),
          Text(
            summary.fromPlans
                ? 'Expected from active customer meal plans.'
                : 'Expected from your active customer count. Assign meal plans '
                    'for per-customer accuracy.',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _MealLine extends StatelessWidget {
  const _MealLine({
    required this.label,
    required this.icon,
    required this.color,
    required this.count,
  });
  final String label;
  final IconData icon;
  final Color color;
  final MealCount count;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      'expected ${count.expected}',
      if (count.cancelled > 0) '−${count.cancelled} cancelled',
      if (count.extra > 0) '+${count.extra} extra',
    ];
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
              Text(parts.join(' · '),
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${count.finalCount}',
                style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w900, color: color)),
            Text('final',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

/// Key tallies: needs review, confirmed/scheduled, active & paused customers.
class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.summary});
  final DashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _MiniStat(
                value: '${summary.pendingCount}',
                label: 'Needs review',
                sub: 'Requests',
                icon: Icons.pending_actions,
                color: const Color(0xFFD97706),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MiniStat(
                value: '${summary.scheduledCount}',
                label: 'Confirmed',
                sub: 'Scheduled',
                icon: Icons.event_available,
                color: const Color(0xFF16A34A),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _MiniStat(
                value: '${summary.activeCustomers}',
                label: 'Active',
                sub: 'Customers',
                icon: Icons.groups,
                color: const Color(0xFF2563EB),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MiniStat(
                value: '${summary.pausedCustomers}',
                label: 'Paused',
                sub: 'Customers',
                icon: Icons.pause_circle_outline,
                color: const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.value,
    required this.label,
    required this.sub,
    required this.icon,
    required this.color,
  });
  final String value;
  final String label;
  final String sub;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            Text(value,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            Text(label,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.onOpenCustomers,
    required this.onOpenImport,
    required this.onOpenRequests,
    required this.onOpenDaily,
    required this.onOpenLedger,
  });
  final VoidCallback onOpenCustomers;
  final VoidCallback onOpenImport;
  final VoidCallback onOpenRequests;
  final VoidCallback onOpenDaily;
  final VoidCallback onOpenLedger;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.7,
      children: [
        _ActionCard(
          icon: Icons.groups,
          label: 'Customers',
          color: const Color(0xFF0D9488),
          onTap: onOpenCustomers,
        ),
        _ActionCard(
          icon: Icons.upload_file,
          label: 'Import chat',
          color: const Color(0xFF2563EB),
          onTap: onOpenImport,
        ),
        _ActionCard(
          icon: Icons.fact_check_outlined,
          label: 'Review requests',
          color: const Color(0xFFD97706),
          onTap: onOpenRequests,
        ),
        _ActionCard(
          icon: Icons.restaurant_menu,
          label: "Today's count",
          color: const Color(0xFF16A34A),
          onTap: onOpenDaily,
        ),
        _ActionCard(
          icon: Icons.account_balance_wallet_outlined,
          label: 'Open ledger',
          color: const Color(0xFF7C3AED),
          onTap: onOpenLedger,
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.item});
  final ActivityItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item.kind) {
      'request_approved' => (Icons.check_circle, const Color(0xFF16A34A)),
      'request_rejected' => (Icons.cancel, const Color(0xFFDC2626)),
      'request_pending' => (Icons.hourglass_bottom, const Color(0xFFD97706)),
      'ledger' => (Icons.account_balance_wallet, const Color(0xFF7C3AED)),
      'import' => (Icons.upload_file, const Color(0xFF2563EB)),
      _ => (Icons.notes, const Color(0xFF334155)),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(item.subtitle,
                    style:
                        TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              ],
            ),
          ),
          Text(relativeTime(item.timestamp),
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
        ],
      ),
    );
  }
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(Icons.inbox_outlined, color: Colors.grey.shade400),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No activity yet. Import a WhatsApp chat to get started.',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }
}
