import 'package:flutter/material.dart';

import '../models/dashboard.dart';
import '../profile/owner_profile.dart';
import '../services/database_service.dart';
import '../services/recent_activity_prefs.dart';
import '../widgets/common.dart';

/// Owner dashboard: greeting, today's final counts, key tallies, quick actions
/// and a recent-activity feed. All figures are live from Supabase.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.profile,
    required this.databaseService,
    required this.onOpenImport,
    required this.onOpenRequests,
    required this.onOpenDaily,
    required this.onOpenLedger,
  });

  final OwnerProfile profile;
  final DatabaseService databaseService;
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

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Base counts changed in Settings: refresh today's totals.
    if (oldWidget.profile.defaultLunchCount !=
            widget.profile.defaultLunchCount ||
        oldWidget.profile.defaultDinnerCount !=
            widget.profile.defaultDinnerCount) {
      reload();
    }
  }

  /// Public so the shell can refresh after imports/approvals.
  Future<void> reload() async {
    if (mounted) setState(() => _error = null);
    try {
      final clearedAt = await _recentActivityPrefs.clearedAt(widget.profile.id);
      final summary = await widget.databaseService.fetchDashboardSummary(
        baseLunch: widget.profile.defaultLunchCount,
        baseDinner: widget.profile.defaultDinnerCount,
      );
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
          _CountRow(lunch: s.finalLunch, dinner: s.finalDinner),
          const SizedBox(height: 12),
          _TallyRow(
            pending: s.pendingCount,
            approvedToday: s.approvedTodayCount,
            imports: s.importedCount,
            latestImport: s.latestImportAt,
          ),
          const SizedBox(height: 16),
          Text('Quick actions',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          _QuickActions(
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

class _CountRow extends StatelessWidget {
  const _CountRow({required this.lunch, required this.dinner});
  final int lunch;
  final int dinner;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _BigCount(
            label: 'Lunch today',
            count: lunch,
            icon: Icons.lunch_dining,
            color: const Color(0xFFEA580C),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _BigCount(
            label: 'Dinner today',
            count: dinner,
            icon: Icons.dinner_dining,
            color: const Color(0xFF7C3AED),
          ),
        ),
      ],
    );
  }
}

class _BigCount extends StatelessWidget {
  const _BigCount({
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
  });
  final String label;
  final int count;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 10),
            Text('$count',
                style: const TextStyle(
                    fontSize: 40, fontWeight: FontWeight.w900, height: 1)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _TallyRow extends StatelessWidget {
  const _TallyRow({
    required this.pending,
    required this.approvedToday,
    required this.imports,
    required this.latestImport,
  });
  final int pending;
  final int approvedToday;
  final int imports;
  final DateTime? latestImport;

  @override
  Widget build(BuildContext context) {
    final importSub =
        latestImport == null ? 'No imports yet' : relativeTime(latestImport);
    return Row(
      children: [
        Expanded(
          child: _MiniStat(
            value: '$pending',
            label: 'Pending',
            sub: 'Need review',
            icon: Icons.pending_actions,
            color: const Color(0xFFD97706),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MiniStat(
            value: '$approvedToday',
            label: 'Approved',
            sub: 'For today',
            icon: Icons.task_alt,
            color: const Color(0xFF16A34A),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MiniStat(
            value: '$imports',
            label: 'Imports',
            sub: importSub,
            icon: Icons.history,
            color: const Color(0xFF2563EB),
          ),
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
    required this.onOpenImport,
    required this.onOpenRequests,
    required this.onOpenDaily,
    required this.onOpenLedger,
  });
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
