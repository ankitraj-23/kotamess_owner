/// Aggregated, privacy-safe proof that a real merchant is actively using the
/// app — for the Week 7 usage-evidence view. Everything here is derived from
/// existing production tables (`chat_imports`, `audit_logs`, `meal_requests`);
/// there is no dedicated events table.
///
/// Time semantics (all rolling windows anchored to the device's local date):
///   * "this week"  == the last 7 days  (today and the 6 days before it)
///   * "last week"  == the 7 days before that (days 7–13 ago)
///   * daily activity covers the last 14 days
/// Timestamps are returned as-is from Supabase (UTC); the UI formats to IST.
class UsageEvidence {
  // --- Activity cadence ---------------------------------------------------
  /// Distinct days with at least one meaningful action in the last 7 days.
  final int activeDaysThisWeek;

  /// Distinct active days in the 7 days before this week.
  final int activeDaysLastWeek;

  /// Consecutive active days ending today (or yesterday, if today has no
  /// activity yet). 0 when the most recent active day is older than yesterday.
  final int currentStreakDays;

  /// Most recent merchant action across imports + audited actions.
  final DateTime? lastActiveAt;

  /// Most recent chat import run.
  final DateTime? lastImportAt;

  // --- Review funnel (this week) ------------------------------------------
  /// Review decisions the owner took on requests this week (confirm / reject /
  /// cancel / complete / edit).
  final int requestsReviewedThisWeek;

  /// Requests the import pipeline extracted from chats this week.
  final int extractedThisWeek;

  /// Requests confirmed (approved) this week.
  final int confirmedThisWeek;

  /// Requests edited this week.
  final int editedThisWeek;

  /// Requests rejected this week.
  final int rejectedThisWeek;

  /// Requests marked completed this week.
  final int completedThisWeek;

  /// Requests currently awaiting review (live snapshot, not windowed).
  final int pendingNow;

  // --- Import throughput (this week) --------------------------------------
  final int importsThisWeek;
  final int messagesImportedThisWeek;
  final int duplicatesSkippedThisWeek;

  // --- Breakdown & feed ---------------------------------------------------
  /// Last 14 days, oldest → newest.
  final List<UsageDayActivity> dailyActivity;

  /// Short, privacy-safe feed of recent actions (no message text, no ids).
  final List<UsageEvidenceActivityItem> recentActivity;

  const UsageEvidence({
    required this.activeDaysThisWeek,
    required this.activeDaysLastWeek,
    required this.currentStreakDays,
    required this.lastActiveAt,
    required this.lastImportAt,
    required this.requestsReviewedThisWeek,
    required this.extractedThisWeek,
    required this.confirmedThisWeek,
    required this.editedThisWeek,
    required this.rejectedThisWeek,
    required this.completedThisWeek,
    required this.pendingNow,
    required this.importsThisWeek,
    required this.messagesImportedThisWeek,
    required this.duplicatesSkippedThisWeek,
    required this.dailyActivity,
    required this.recentActivity,
  });

  /// True when there is no usage to show at all — lets the UI render an empty
  /// state instead of a wall of zeros.
  bool get isEmpty =>
      activeDaysThisWeek == 0 &&
      activeDaysLastWeek == 0 &&
      importsThisWeek == 0 &&
      requestsReviewedThisWeek == 0 &&
      pendingNow == 0 &&
      recentActivity.isEmpty;
}

/// One day in the 14-day activity strip.
class UsageDayActivity {
  /// Local calendar day at midnight.
  final DateTime date;
  final int imports;
  final int messagesProcessed;
  final int extracted;

  /// Review decisions logged on this day.
  final int reviewed;
  final int duplicatesSkipped;

  /// Any import or any audited action happened on this day.
  final bool active;

  const UsageDayActivity({
    required this.date,
    required this.imports,
    required this.messagesProcessed,
    required this.extracted,
    required this.reviewed,
    required this.duplicatesSkipped,
    required this.active,
  });
}

/// A single privacy-safe row in the usage-evidence feed. [kind] is a stable
/// string the UI maps to an icon/colour. Titles/subtitles never contain raw
/// WhatsApp text or internal ids.
class UsageEvidenceActivityItem {
  final String kind; // 'import' | 'review'
  final String title;
  final String subtitle;
  final DateTime? timestamp;

  const UsageEvidenceActivityItem({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.timestamp,
  });
}
