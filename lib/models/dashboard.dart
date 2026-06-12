/// Headline numbers + recent activity shown on the Home dashboard.
class DashboardSummary {
  final int finalLunch;
  final int finalDinner;
  final int pendingCount;
  final int approvedTodayCount;
  final int importedCount;
  final DateTime? latestImportAt;
  final List<ActivityItem> recentActivity;

  DashboardSummary({
    required this.finalLunch,
    required this.finalDinner,
    required this.pendingCount,
    required this.approvedTodayCount,
    required this.importedCount,
    required this.latestImportAt,
    required this.recentActivity,
  });

  bool get isEmpty =>
      pendingCount == 0 &&
      approvedTodayCount == 0 &&
      importedCount == 0 &&
      recentActivity.isEmpty;
}

/// A single line in the Home "Recent activity" feed. [kind] is a stable string
/// the UI maps to an icon/colour, keeping this model UI-framework free.
class ActivityItem {
  final String kind; // request_pending | request_approved | request_rejected | ledger | import
  final String title;
  final String subtitle;
  final DateTime? timestamp;

  ActivityItem({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.timestamp,
  });
}
