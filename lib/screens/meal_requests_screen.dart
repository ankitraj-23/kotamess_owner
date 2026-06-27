import 'package:flutter/material.dart';

import '../models/meal_request.dart';
import '../models/student.dart';
import '../services/database_service.dart';
import '../widgets/confidence_badge.dart';

/// Review extracted meal requests: filter, search, approve/reject/edit/delete,
/// and batch-approve selected pending items.
class MealRequestsScreen extends StatefulWidget {
  const MealRequestsScreen({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<MealRequestsScreen> createState() => MealRequestsScreenState();
}

class MealRequestsScreenState extends State<MealRequestsScreen> {
  final _search = TextEditingController();

  String _filter = 'pending'; // pending | approved | rejected | all
  bool _loading = true;
  String? _error;
  List<MealRequest> _items = [];
  final Set<String> _selected = {};

  /// Requests with an in-flight status mutation. Drives per-card loading so
  /// only the tapped card's actions are disabled, never the whole screen.
  final Set<String> _busyRequestIds = {};

  /// Request ids that already have a linked ledger entry (for the badge).
  Set<String> _ledgerLinked = {};

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

  /// Public so the shell can refresh after an import saves new requests.
  ///
  /// [silent] skips the full-page spinner and keeps the current list visible
  /// on failure — used after a mutation so the screen never blanks/reloads
  /// under the owner. Pull-to-refresh and filter changes use the full path.
  Future<void> reload({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final items = await widget.databaseService.fetchMealRequests(
        status: _filter,
        search: _search.text,
      );
      final linked = await widget.databaseService.fetchRequestIdsWithLedger();
      if (!mounted) return;
      setState(() {
        _items = items;
        _ledgerLinked = linked;
        _selected.removeWhere((id) => !items.any((r) => r.id == id));
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (silent) return; // keep the current list; the action already landed
      setState(() {
        _error = 'Could not load requests. Pull to refresh.';
        _loading = false;
      });
    }
  }

  /// Shows a single short success/error message, replacing any current one so
  /// rapid actions don't stack a tower of SnackBars.
  void _showSnack(String message, {int seconds = 1}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: Duration(seconds: seconds)),
    );
  }

  /// Optimistic status change: flips the local status (and drops the card from
  /// the list if it no longer matches the active filter) immediately, then runs
  /// the DB update in the background. On failure it reverts and reports it.
  Future<void> _mutateStatus(
    MealRequest r,
    String newStatus,
    Future<void> Function() action,
    String done,
  ) async {
    if (_busyRequestIds.contains(r.id)) return;
    final oldStatus = r.status;
    final oldIndex = _items.indexOf(r);
    // Drop from the list when the new status leaves the current filter (e.g.
    // approving a card while viewing "Needs review"). 'all' keeps every card.
    final leavesFilter = _filter != 'all' && newStatus != _filter;

    setState(() {
      _busyRequestIds.add(r.id);
      r.status = newStatus;
      _selected.remove(r.id);
      if (leavesFilter) _items.removeWhere((x) => x.id == r.id);
    });

    try {
      await action();
      if (!mounted) return;
      setState(() => _busyRequestIds.remove(r.id));
      _showSnack(done);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busyRequestIds.remove(r.id);
        r.status = oldStatus;
        if (leavesFilter && !_items.any((x) => x.id == r.id)) {
          final at = (oldIndex >= 0 && oldIndex <= _items.length)
              ? oldIndex
              : _items.length;
          _items.insert(at, r);
        }
      });
      _showSnack('Action failed. Please try again.');
    }
  }

  void _setFilter(String filter) {
    setState(() {
      _filter = filter;
      _selected.clear();
    });
    reload();
  }

  Future<void> _approve(MealRequest r) async {
    // Unresolved senders can't be approved — point the owner at the fix and
    // open the linking sheet directly so resolving is one tap away.
    if (r.isSenderUnresolved) {
      _showSnack('Resolve the student before approving this request.',
          seconds: 3);
      _linkStudent(r);
      return;
    }
    final addsLedger =
        r.requestType == 'payment_note' || r.requestType == 'dues_query';
    await _mutateStatus(
      r,
      'approved',
      () => widget.databaseService.approveMealRequest(r.id),
      addsLedger ? 'Approved · added to Ledger' : 'Approved',
    );
  }

  /// Decides what the unresolved-request primary button should do, keeping the
  /// production-safe rules intact:
  ///   * ambiguous (duplicate saved name) / unreliable sender → owner MUST pick
  ///     the right existing customer first; never auto-create.
  ///   * needs_review / unlinked WITH candidates → open the resolve sheet.
  ///   * needs_review / unlinked WITHOUT candidates and a usable name → one-tap
  ///     "Create customer & approve".
  ///   * otherwise (no safe name) → manual resolve.
  ({String label, VoidCallback onPressed}) _resolveMode(MealRequest r) {
    if (r.isAmbiguousSender || r.isUnreliableSender) {
      return (label: 'Resolve first', onPressed: () => _linkStudent(r));
    }
    if (r.hasResolveCandidates) {
      return (label: 'Resolve', onPressed: () => _linkStudent(r));
    }
    if (r.canCreateCustomerFromName) {
      return (
        label: 'Create customer & approve',
        onPressed: () => _createCustomerAndApprove(r),
      );
    }
    return (label: 'Resolve first', onPressed: () => _linkStudent(r));
  }

  /// One-tap path for a safe `needs_review` request with no candidates: create
  /// a new active customer from the extracted name, link this request to it
  /// (saving the name as an alias), then approve. Guarded so an unreliable /
  /// empty / "Unknown" name can never silently create a customer.
  Future<void> _createCustomerAndApprove(MealRequest r) async {
    if (!r.canCreateCustomerFromName) {
      _showSnack('Resolve the student before approving this request.',
          seconds: 3);
      _linkStudent(r);
      return;
    }
    final name = r.studentName.trim();
    final addsLedger =
        r.requestType == 'payment_note' || r.requestType == 'dues_query';
    await _mutateStatus(
      r,
      'approved',
      () async {
        final created =
            await widget.databaseService.createCustomer(name: name);
        await widget.databaseService.linkRequestToStudent(
          requestId: r.id,
          studentId: created.id,
          canonicalName: created.name,
          aliasToSave: name,
        );
        // Keep the local model in step so the safety guard in approve sees a
        // linked request.
        r.studentId = created.id;
        await widget.databaseService.approveMealRequest(r.id);
      },
      addsLedger ? 'Customer created · Approved · added to Ledger'
          : 'Customer created · Approved',
    );
  }

  /// Opens the link/alias sheet so the owner can attach this request to an
  /// existing student (saving the extracted name as an alias) or create one.
  Future<void> _linkStudent(MealRequest r) async {
    final linked = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LinkStudentSheet(
        databaseService: widget.databaseService,
        request: r,
      ),
    );
    if (linked == true) {
      _showSnack('Student linked.');
      reload(silent: true);
    }
  }

  Future<void> _reject(MealRequest r) async {
    await _mutateStatus(r, 'rejected',
        () => widget.databaseService.rejectMealRequest(r.id), 'Rejected');
  }

  Future<void> _markCompleted(MealRequest r) async {
    await _mutateStatus(r, 'completed',
        () => widget.databaseService.markRequestCompleted(r.id), 'Completed');
  }

  Future<void> _cancel(MealRequest r) async {
    await _mutateStatus(r, 'cancelled',
        () => widget.databaseService.cancelRequest(r.id), 'Cancelled');
  }

  /// Opens a small dialog to add/edit the owner's private note on a request.
  Future<void> _addNote(MealRequest r) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _OwnerNoteDialog(initial: r.ownerNote),
    );
    if (!mounted) return;
    // Cancelled or dismissed: leave the request untouched.
    if (note == null) return;
    // No actual change: don't fire an unnecessary update.
    if (note == r.ownerNote.trim()) return;
    await _guard(
        () => widget.databaseService.addOwnerNote(r.id, note), 'Note saved');
  }

  Future<void> _approveSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    try {
      final res = await widget.databaseService.approveMany(ids);
      if (!mounted) return;
      final msg = res.skipped == 0
          ? 'Approved ${res.approved} linked requests.'
          : 'Approved ${res.approved} linked requests. Skipped ${res.skipped} '
              'unclear requests that need student review.';
      _showSnack(msg, seconds: 3);
      await reload(silent: true);
    } catch (_) {
      _showSnack('Action failed. Please try again.');
    }
  }

  Future<void> _delete(MealRequest r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete request?'),
        content: Text('Delete the request from ${r.studentName}?'),
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
    await _guard(
        () => widget.databaseService.deleteMealRequest(r.id), 'Deleted');
  }

  Future<void> _edit(MealRequest r) async {
    final updated = await showModalBottomSheet<MealRequest>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _EditRequestSheet(original: r),
    );
    if (updated == null) return;
    await _guard(
      () => widget.databaseService.updateMealRequest(updated),
      'Saved',
    );
  }

  /// Runs a one-off mutation (edit/note/delete/link/batch), shows a single
  /// SnackBar, then silently refreshes so the list stays put — no full-page
  /// spinner. Status changes use [_mutateStatus] instead.
  Future<void> _guard(Future<void> Function() action, String done) async {
    try {
      await action();
      if (!mounted) return;
      _showSnack(done);
      await reload(silent: true);
    } catch (_) {
      _showSnack('Action failed. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSelection = _filter == 'pending';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Review requests',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('Needs review', 'pending'),
                    _filterChip('Confirmed', 'approved'),
                    _filterChip('Completed', 'completed'),
                    _filterChip('Cancelled', 'cancelled'),
                    _filterChip('Rejected', 'rejected'),
                    _filterChip('All', 'all'),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => reload(),
                decoration: InputDecoration(
                  hintText: 'Search by student name',
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
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                  isDense: true,
                ),
              ),
              if (showSelection && _selected.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _approveSelected,
                    icon: const Icon(Icons.done_all),
                    label: Text('Approve ${_selected.length} selected'),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(child: _buildBody(showSelection)),
      ],
    );
  }

  Widget _buildBody(bool showSelection) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            _Banner(message: _error!, color: Colors.red)
          else if (_items.isEmpty)
            const _EmptyRequests()
          else
            ..._items.map((r) {
              final unresolved = r.isSenderUnresolved;
              // For a pending unresolved request, pick the owner-friendly
              // primary action (Approve is replaced by Resolve / Create).
              final resolve =
                  (unresolved && r.status == 'pending') ? _resolveMode(r) : null;
              return _RequestCard(
                  request: r,
                  selectable: showSelection,
                  selected: _selected.contains(r.id),
                  busy: _busyRequestIds.contains(r.id),
                  unresolved: unresolved,
                  resolveLabel: resolve?.label,
                  onResolve: resolve?.onPressed,
                  ledgerLinked: _ledgerLinked.contains(r.id),
                  onSelectedChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(r.id);
                    } else {
                      _selected.remove(r.id);
                    }
                  }),
                  onApprove: (r.status == 'pending' && !unresolved)
                      ? () => _approve(r)
                      : null,
                  onReject: r.status == 'pending' ? () => _reject(r) : null,
                  onEdit: () => _edit(r),
                  onLink: () => _linkStudent(r),
                  onDelete: () => _delete(r),
                  onComplete:
                      r.status == 'approved' ? () => _markCompleted(r) : null,
                  onCancel: (r.status == 'pending' || r.status == 'approved')
                      ? () => _cancel(r)
                      : null,
                  onAddNote: () => _addNote(r),
                );
            }),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == value,
        onSelected: (_) => _setFilter(value),
      ),
    );
  }
}

/// Small dialog that owns its [TextEditingController] so the controller is
/// only disposed once this widget's element is fully unmounted — never while
/// the dialog route is still mounted/animating out. Pops the trimmed note text
/// on Save, or null when cancelled/dismissed.
class _OwnerNoteDialog extends StatefulWidget {
  const _OwnerNoteDialog({required this.initial});

  final String initial;

  @override
  State<_OwnerNoteDialog> createState() => _OwnerNoteDialogState();
}

class _OwnerNoteDialogState extends State<_OwnerNoteDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Owner note'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 4,
        decoration: const InputDecoration(
          hintText: 'Private note for this request',
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _controller.text.trim()),
            child: const Text('Save')),
      ],
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.selectable,
    required this.selected,
    required this.busy,
    required this.unresolved,
    required this.resolveLabel,
    required this.onResolve,
    required this.ledgerLinked,
    required this.onSelectedChanged,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
    required this.onLink,
    required this.onDelete,
    required this.onComplete,
    required this.onCancel,
    required this.onAddNote,
  });

  final MealRequest request;
  final bool selectable;
  final bool selected;
  final bool busy;

  /// Sender could not be linked to a real student — approval is blocked until
  /// the owner resolves it.
  final bool unresolved;

  /// Owner-friendly label for the primary action of an unresolved pending
  /// request ("Resolve first" / "Resolve" / "Create customer & approve").
  /// Null when the request is resolved (a plain Approve is shown instead).
  final String? resolveLabel;
  final VoidCallback? onResolve;
  final bool ledgerLinked;
  final ValueChanged<bool?> onSelectedChanged;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback onEdit;
  final VoidCallback onLink;
  final VoidCallback onDelete;
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;
  final VoidCallback onAddNote;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (selectable)
                  Checkbox(value: selected, onChanged: onSelectedChanged),
                Expanded(
                  child: Text(request.studentName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                ConfidenceBadge(confidence: request.confidence),
                PopupMenuButton<String>(
                  onSelected: (v) => switch (v) {
                    'edit' => onEdit(),
                    'note' => onAddNote(),
                    'complete' => onComplete?.call(),
                    'cancel' => onCancel?.call(),
                    'link' => onLink(),
                    _ => onDelete(),
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    const PopupMenuItem(
                        value: 'note', child: Text('Add / edit note')),
                    if (onComplete != null)
                      const PopupMenuItem(
                          value: 'complete', child: Text('Mark completed')),
                    if (onCancel != null)
                      const PopupMenuItem(
                          value: 'cancel', child: Text('Cancel request')),
                    const PopupMenuItem(
                        value: 'link', child: Text('Link student…')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Tag(request.requestTypeLabel),
                // Quantity deltas take priority over the plain meal label so the
                // owner sees "Lunch +2" / "Dinner -1" at a glance. Fall back to
                // the meal-type label only when there is no quantity change.
                if (request.hasQuantityChange) ...[
                  if (request.lunchDeltaLabel != null)
                    _DeltaTag(request.lunchDeltaLabel!, request.lunchDelta),
                  if (request.dinnerDeltaLabel != null)
                    _DeltaTag(request.dinnerDeltaLabel!, request.dinnerDelta),
                ] else if (request.mealType != 'none')
                  _Tag(request.mealTypeLabel),
                _Tag(request.dateDisplay),
                _StatusTag(status: request.status),
                if (request.isLateRequest) const _LateTag(),
                if (unresolved) _ResolveTag(label: request.linkStatusLabel),
                if (ledgerLinked) const _Tag('Ledger linked'),
              ],
            ),
            if (request.isLateRequest &&
                (request.lateReason?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.schedule, size: 14, color: Colors.red.shade700),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(request.lateReason!,
                        style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text('“${request.originalMessage}”',
                style: TextStyle(color: Colors.grey.shade800)),
            if (request.reason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(request.reason,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],
            if (request.ownerNote.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.sticky_note_2_outlined,
                      size: 14, color: Colors.amber.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Note: ${request.ownerNote}',
                        style: TextStyle(
                            color: Colors.amber.shade900,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
            if (onApprove != null || onReject != null || onResolve != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onReject != null)
                    TextButton.icon(
                      onPressed: busy ? null : onReject,
                      icon: const Icon(Icons.close),
                      label: const Text('Reject'),
                    ),
                  const SizedBox(width: 6),
                  // Unresolved senders can't be confirmed directly — show the
                  // owner-friendly resolve/create action chosen by the parent.
                  if (onResolve != null)
                    OutlinedButton.icon(
                      onPressed: busy ? null : onResolve,
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.person_search, size: 18),
                      label: Text(resolveLabel ?? 'Resolve first'),
                    )
                  else if (onApprove != null)
                    FilledButton.icon(
                      onPressed: busy ? null : onApprove,
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check),
                      label: const Text('Approve'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }
}

/// Signed quantity chip for a meal change, e.g. "Lunch +2" (green) or
/// "Dinner -1" (red). Positive deltas add meals, negative deltas remove them.
class _DeltaTag extends StatelessWidget {
  final String text;
  final int delta;
  const _DeltaTag(this.text, this.delta);

  @override
  Widget build(BuildContext context) {
    final positive = delta > 0;
    final bg = positive ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2);
    final fg = positive ? const Color(0xFF166534) : const Color(0xFF991B1B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

/// Amber "needs resolving" badge for a request whose WhatsApp sender could not
/// be linked to a real student. Shows the link-status label (e.g. "Ambiguous
/// name", "Unclear sender", "Not linked") with a person-search icon.
class _ResolveTag extends StatelessWidget {
  const _ResolveTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_search, size: 12, color: Colors.amber.shade900),
          const SizedBox(width: 4),
          Text('Resolve student · $label',
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.amber.shade900,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Visible flag for a request that arrived after the owner's cutoff window.
class _LateTag extends StatelessWidget {
  const _LateTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 12, color: Colors.red.shade700),
          const SizedBox(width: 4),
          Text('Late',
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  final String status;
  const _StatusTag({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'approved' => Colors.green,
      'completed' => Colors.blue,
      'rejected' => Colors.red,
      'cancelled' => Colors.blueGrey,
      _ => Colors.orange,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        MealRequestVocab.statusLabel(status),
        style: TextStyle(
            fontSize: 12, color: color.shade700, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String message;
  final MaterialColor color;
  const _Banner({required this.message, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.shade200),
      ),
      child: Text(message, style: TextStyle(color: color.shade700)),
    );
  }
}

class _EmptyRequests extends StatelessWidget {
  const _EmptyRequests();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, size: 48, color: Colors.grey.shade500),
          const SizedBox(height: 10),
          const Text('No requests here',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 4),
          const Text('Import a WhatsApp chat or switch filters.',
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// Bottom-sheet editor for a meal request. Returns an updated [MealRequest]
/// (a copy of [original] with the edited fields) via Navigator.pop, or null.
class _EditRequestSheet extends StatefulWidget {
  final MealRequest original;
  const _EditRequestSheet({required this.original});

  @override
  State<_EditRequestSheet> createState() => _EditRequestSheetState();
}

class _EditRequestSheetState extends State<_EditRequestSheet> {
  late final TextEditingController _name;
  late final TextEditingController _dateLabel;
  late final TextEditingController _reason;
  late String _requestType;
  late String _mealType;
  late int _lunchDelta;
  late int _dinnerDelta;
  String? _requestDate;

  @override
  void initState() {
    super.initState();
    final r = widget.original;
    _name = TextEditingController(text: r.studentName);
    _dateLabel = TextEditingController(text: r.dateLabel ?? '');
    _reason = TextEditingController(text: r.reason);
    _requestType = r.requestType;
    _mealType = r.mealType;
    _lunchDelta = r.lunchDelta;
    _dinnerDelta = r.dinnerDelta;
    _requestDate = r.requestDate;
  }

  @override
  void dispose() {
    _name.dispose();
    _dateLabel.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(_requestDate ?? '') ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) {
      setState(() {
        _requestDate =
            '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      });
    }
  }

  void _save() {
    final r = widget.original;
    r.studentName = _name.text.trim().isEmpty ? 'Unknown' : _name.text.trim();
    r.requestType = _requestType;
    r.mealType = _mealType;
    r.lunchDelta = _lunchDelta;
    r.dinnerDelta = _dinnerDelta;
    r.dateLabel =
        _dateLabel.text.trim().isEmpty ? null : _dateLabel.text.trim();
    r.requestDate = _requestDate;
    r.reason = _reason.text.trim();
    Navigator.pop(context, r);
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
            const Text('Edit request',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Student name',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _requestType,
              decoration: const InputDecoration(labelText: 'Request type'),
              items: MealRequestVocab.requestTypes
                  .map((t) => DropdownMenuItem(
                      value: t, child: Text(MealRequestVocab.typeLabel(t))))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _requestType = v ?? _requestType),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _mealType,
              decoration: const InputDecoration(labelText: 'Meal type'),
              items: MealRequestVocab.mealTypes
                  .map((t) => DropdownMenuItem(
                      value: t, child: Text(MealRequestVocab.mealLabel(t))))
                  .toList(),
              onChanged: (v) => setState(() => _mealType = v ?? _mealType),
            ),
            const SizedBox(height: 16),
            _DeltaStepper(
              label: 'Lunch change',
              value: _lunchDelta,
              onChanged: (v) => setState(() => _lunchDelta = v),
            ),
            const SizedBox(height: 12),
            _DeltaStepper(
              label: 'Dinner change',
              value: _dinnerDelta,
              onChanged: (v) => setState(() => _dinnerDelta = v),
            ),
            const SizedBox(height: 6),
            Text('+2 means add 2, -1 means cancel/remove 1',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: _dateLabel,
              decoration: const InputDecoration(
                labelText: 'Date label (e.g. today, tomorrow, Sunday)',
                prefixIcon: Icon(Icons.event_note_outlined),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(_requestDate == null
                      ? 'No exact date'
                      : 'Date: $_requestDate'),
                ),
                TextButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: const Text('Pick date'),
                ),
                if (_requestDate != null)
                  IconButton(
                    tooltip: 'Clear date',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _requestDate = null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason / note',
                prefixIcon: Icon(Icons.notes_outlined),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    child: const Text('Save changes'),
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

/// Plus/minus stepper for a signed meal-quantity delta. Supports positive,
/// negative and zero values; the middle field accepts direct integer entry
/// (including a leading "-") and ignores anything non-integer.
class _DeltaStepper extends StatefulWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  const _DeltaStepper({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_DeltaStepper> createState() => _DeltaStepperState();
}

class _DeltaStepperState extends State<_DeltaStepper> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value.toString());

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _set(int v) {
    widget.onChanged(v);
    final text = v.toString();
    if (_controller.text != text) {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(widget.label,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: 'Decrease',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: () => _set(widget.value - 1),
        ),
        SizedBox(
          width: 56,
          child: TextField(
            controller: _controller,
            textAlign: TextAlign.center,
            keyboardType:
                const TextInputType.numberWithOptions(signed: true),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            onChanged: (text) {
              final t = text.trim();
              if (t.isEmpty || t == '-') {
                widget.onChanged(0);
                return;
              }
              final parsed = int.tryParse(t);
              if (parsed != null) widget.onChanged(parsed);
            },
          ),
        ),
        IconButton(
          tooltip: 'Increase',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () => _set(widget.value + 1),
        ),
      ],
    );
  }
}

/// Links a request's extracted name to a canonical student. Suggests existing
/// matches (exact / alias / partial), lets the owner search, and can create a
/// new student. Linking saves the extracted name as an alias so future imports
/// of that spelling auto-link. Pops `true` when a link was made.
class _LinkStudentSheet extends StatefulWidget {
  const _LinkStudentSheet(
      {required this.databaseService, required this.request});
  final DatabaseService databaseService;
  final MealRequest request;

  @override
  State<_LinkStudentSheet> createState() => _LinkStudentSheetState();
}

class _LinkStudentSheetState extends State<_LinkStudentSheet> {
  late final TextEditingController _query =
      TextEditingController(text: widget.request.studentName);
  List<StudentCandidate> _candidates = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    try {
      final matches =
          await widget.databaseService.findStudentMatches(_query.text);
      if (!mounted) return;
      setState(() {
        _candidates = matches;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not search students.';
      });
    }
  }

  Future<void> _runLink(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not link this student. Please try again.';
      });
    }
  }

  // For duplicate-name ambiguity ("two students named Rahul") we link THIS
  // request only and never remember the generic name as a global alias.
  String? get _aliasToSave =>
      widget.request.isAmbiguousSender ? null : widget.request.studentName;

  void _linkTo(Student s) =>
      _runLink(() => widget.databaseService.linkRequestToStudent(
            requestId: widget.request.id,
            studentId: s.id,
            canonicalName: s.name,
            aliasToSave: _aliasToSave,
          ));

  void _createNew() => _runLink(() async {
        final created =
            await widget.databaseService.createStudent(_query.text.trim());
        await widget.databaseService.linkRequestToStudent(
          requestId: widget.request.id,
          studentId: created.id,
          canonicalName: created.name,
          aliasToSave: _aliasToSave,
        );
      });

  @override
  Widget build(BuildContext context) {
    final canCreate = _query.text.trim().isNotEmpty;
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
            const Text('Link student',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Extracted as “${widget.request.studentName}”',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 14),
            TextField(
              controller: _query,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: 'Search existing students',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Search',
                  onPressed: _busy ? null : _search,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_candidates.isEmpty)
              Text('No matching students yet.',
                  style: TextStyle(color: Colors.grey.shade600))
            else
              ..._candidates.map((c) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      child: Text(c.student.name.isEmpty
                          ? '?'
                          : c.student.name[0].toUpperCase()),
                    ),
                    title: Text(c.student.name,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(c.reasonLabel),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _linkTo(c.student),
                      child: const Text('Link'),
                    ),
                  )),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
            ],
            const Divider(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (_busy || !canCreate) ? null : _createNew,
                icon: const Icon(Icons.person_add_alt),
                label: Text(canCreate
                    ? 'Create new student “${_query.text.trim()}”'
                    : 'Enter a name to create a student'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
