import 'package:flutter/material.dart';

import '../models/chat_import.dart';
import '../models/chat_message.dart';
import '../models/meal_request.dart';
import '../models/student.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';
import 'import_history_screen.dart' show ImportStatusChip;

/// Detail for one import run: summary counts, status/error, the requests it
/// extracted (`meal_requests` linked by `import_id`) and the messages it parsed
/// (`chat_messages`).
///
/// NOTE on "Review requests from this import": the Requests screen lives in the
/// bottom-nav shell and has no `import_id` filter, so cross-navigating with a
/// filter would be intrusive. Instead we show the linked requests inline here
/// and the button scrolls to that section. (Documented limitation.)
class ImportDetailScreen extends StatefulWidget {
  const ImportDetailScreen({
    super.key,
    required this.databaseService,
    required this.chatImport,
  });

  final DatabaseService databaseService;
  final ChatImport chatImport;

  @override
  State<ImportDetailScreen> createState() => _ImportDetailScreenState();
}

class _ImportDetailScreenState extends State<ImportDetailScreen> {
  bool _loading = true;
  String? _error;
  List<MealRequest> _requests = [];
  List<ChatMessage> _messages = [];
  List<Student> _students = [];

  final _requestsKey = GlobalKey();

  /// Requests whose WhatsApp sender could not be confidently linked.
  List<MealRequest> get _unclear =>
      _requests.where((r) => r.isSenderUnresolved).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = widget.databaseService;
      final requests = await db.fetchRequestsForImport(widget.chatImport.id);
      final messages = await db.fetchChatMessages(widget.chatImport.id);
      // Full customer rows (phone/room/status) so the review candidates can show
      // the fields that help Priya tell two same-named students apart.
      final students = await db.fetchCustomers();
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _messages = messages;
        _students = students;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this import. Pull to refresh.';
        _loading = false;
      });
    }
  }

  void _scrollToRequests() {
    final ctx = _requestsKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
      alignment: 0.05,
    );
  }

  /// Opens the resolver sheet for one unclear sender. On a successful link it
  /// refreshes so the request drops out of the review section.
  Future<void> _resolveSender(MealRequest r) async {
    final linked = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ResolveSenderSheet(
        databaseService: widget.databaseService,
        request: r,
        students: _students,
      ),
    );
    if (linked == true && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Request linked.'),
            duration: Duration(seconds: 1)));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final imp = widget.chatImport;
    return Scaffold(
      appBar: AppBar(title: const Text('Import details')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SummaryCard(chatImport: imp),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _requests.isEmpty ? null : _scrollToRequests,
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(_requests.isEmpty
                    ? 'No requests from this import'
                    : 'Review requests from this import'),
              ),
            ),
            const SizedBox(height: 20),
            if (_error != null)
              _InlineError(message: _error!, onRetry: _load)
            else if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (_unclear.isNotEmpty) ...[
                _UnclearSendersSection(
                  unclear: _unclear,
                  students: _students,
                  onResolve: _resolveSender,
                ),
                const SizedBox(height: 20),
              ],
              _SectionHeader(
                key: _requestsKey,
                title: 'Extracted requests',
                count: _requests.length,
              ),
              const SizedBox(height: 8),
              if (_requests.isEmpty)
                const _EmptyHint('No requests were linked to this import.')
              else
                ..._requests.map((r) => _RequestTile(request: r)),
              const SizedBox(height: 20),
              _SectionHeader(
                title: 'Parsed messages',
                count: _messages.length,
                suffix: _messages.length >= 50 ? ' (latest 50)' : '',
              ),
              const SizedBox(height: 8),
              if (_messages.isEmpty)
                const _EmptyHint('No parsed messages were saved for this import.')
              else
                ..._messages.map((m) => _MessageTile(message: m)),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.chatImport});

  final ChatImport chatImport;

  @override
  Widget build(BuildContext context) {
    final imp = chatImport;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    imp.title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                ImportStatusChip(status: imp.status, label: imp.statusLabel),
              ],
            ),
            const SizedBox(height: 4),
            Text('Source: ${imp.sourceLabel}',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
            Text('Imported ${formatStamp(imp.createdAt)}',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const Divider(height: 22),
            _CountRow('Total messages', imp.totalMessages),
            _CountRow('Processed messages', imp.processedMessages),
            _CountRow('Skipped (older than 90 days)', imp.skippedOldMessages),
            const Divider(height: 22),
            _CountRow('Extracted requests', imp.extractedCount, emphasize: true),
            _CountRow('Possible duplicates', imp.duplicateCount),
            _CountRow('Needs review / rejected', imp.rejectedCount),
            if (imp.isFailed && (imp.errorMessage?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline,
                        color: Colors.red.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(imp.errorMessage!,
                          style: TextStyle(color: Colors.red.shade700)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow(this.label, this.value, {this.emphasize = false});

  final String label;
  final int value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final weight = emphasize ? FontWeight.w800 : FontWeight.w500;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontWeight: weight))),
          Text('$value',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.title,
    required this.count,
    this.suffix = '',
  });

  final String title;
  final int count;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$title ($count)$suffix',
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.request});

  final MealRequest request;

  @override
  Widget build(BuildContext context) {
    final r = request;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.studentName,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                InfoPill(r.requestTypeLabel),
                if (r.mealType != 'none') InfoPill(r.mealTypeLabel),
                InfoPill(r.dateDisplay),
                InfoPill(r.statusLabel, color: _statusColor(r.status)),
                if (r.isDuplicateFlagged)
                  InfoPill(r.duplicateStatusLabel,
                      color: const Color(0xFFD97706)),
              ],
            ),
            if (r.originalMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('“${r.originalMessage}”',
                  style: TextStyle(color: Colors.grey.shade800, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return const Color(0xFF16A34A);
      case 'completed':
        return const Color(0xFF2563EB);
      case 'rejected':
        return const Color(0xFFDC2626);
      case 'cancelled':
        return const Color(0xFF64748B);
      default:
        return const Color(0xFFEA580C);
    }
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final m = message;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(m.senderLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                if (m.isProcessed)
                  Icon(Icons.check_circle_outline,
                      size: 16, color: Colors.green.shade600),
              ],
            ),
            const SizedBox(height: 4),
            Text(m.messageText,
                style: TextStyle(color: Colors.grey.shade800, fontSize: 13)),
            if (m.messageTimestamp != null) ...[
              const SizedBox(height: 4),
              Text(formatStamp(m.messageTimestamp),
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(text, style: TextStyle(color: Colors.grey.shade600)),
    );
  }
}

/// "Review unclear students" — the ambiguous-sender review flow. Lists every
/// request whose WhatsApp sender could not be safely linked to one customer and
/// lets the owner resolve each one. Shown only when there is something to fix.
class _UnclearSendersSection extends StatelessWidget {
  const _UnclearSendersSection({
    required this.unclear,
    required this.students,
    required this.onResolve,
  });

  final List<MealRequest> unclear;
  final List<Student> students;
  final Future<void> Function(MealRequest) onResolve;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.help_outline, color: Colors.amber.shade800, size: 20),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Review unclear students (${unclear.length})',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.amber.shade200),
          ),
          child: Text(
            'WhatsApp export uses your saved contact name. If two students are '
            'saved as the same name, Kotamess cannot safely know who sent the '
            'message — so it leaves these unlinked for you to confirm.',
            style: TextStyle(color: Colors.amber.shade900, fontSize: 12.5),
          ),
        ),
        const SizedBox(height: 10),
        ...unclear.map((r) => _UnclearSenderTile(
              request: r,
              students: students,
              onResolve: () => onResolve(r),
            )),
      ],
    );
  }
}

class _UnclearSenderTile extends StatelessWidget {
  const _UnclearSenderTile({
    required this.request,
    required this.students,
    required this.onResolve,
  });

  final MealRequest request;
  final List<Student> students;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final sender = (r.senderRaw?.trim().isNotEmpty ?? false)
        ? r.senderRaw!.trim()
        : r.studentName;
    final candidates = students
        .where((s) => r.candidateStudentIds.contains(s.id))
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Sent as “$sender”',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                ),
                InfoPill(r.linkStatusLabel, color: _linkColor(r.linkStatus)),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                InfoPill(r.requestTypeLabel),
                if (r.mealType != 'none') InfoPill(r.mealTypeLabel),
                InfoPill(r.dateDisplay),
              ],
            ),
            if (r.originalMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('“${r.originalMessage}”',
                  style: TextStyle(color: Colors.grey.shade800, fontSize: 13)),
            ],
            if ((r.linkReason?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 6),
              Text(r.linkReason!,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],
            if (candidates.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Possible: ${candidates.map(_studentSummary).join(' · ')}',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
              ),
            ],
            if (r.isAmbiguousSender) ...[
              const SizedBox(height: 8),
              const _NudgeTip(),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: onResolve,
                icon: const Icon(Icons.person_search, size: 18),
                label: const Text('Resolve'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _studentSummary(Student s) {
    final extra = <String>[
      if (s.roomOrAddress.trim().isNotEmpty) s.roomOrAddress.trim(),
      if (s.phone.trim().isNotEmpty) s.phone.trim(),
    ];
    return extra.isEmpty ? s.name : '${s.name} (${extra.join(', ')})';
  }

  Color _linkColor(String? status) {
    switch (status) {
      case 'ambiguous':
        return const Color(0xFFD97706);
      case 'unreliable_sender':
        return const Color(0xFF7C3AED);
      default:
        return const Color(0xFFEA580C);
    }
  }
}

/// The reliability nudge — shown only for duplicate-saved-name ambiguity.
class _NudgeTip extends StatelessWidget {
  const _NudgeTip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 16, color: Colors.blue.shade700),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Tip: rename duplicate WhatsApp contacts with a unique hint, like '
              '“Rahul 204” or “Rahul 317”. Future exports will then be easier '
              'to match.',
              style: TextStyle(color: Colors.blue.shade900, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Resolver for one unclear sender: pick the right customer (or leave it). For
/// duplicate-name ambiguity, linking fixes THIS request only and never saves
/// the generic name as a global alias.
class _ResolveSenderSheet extends StatefulWidget {
  const _ResolveSenderSheet({
    required this.databaseService,
    required this.request,
    required this.students,
  });

  final DatabaseService databaseService;
  final MealRequest request;
  final List<Student> students;

  @override
  State<_ResolveSenderSheet> createState() => _ResolveSenderSheetState();
}

class _ResolveSenderSheetState extends State<_ResolveSenderSheet> {
  late final TextEditingController _query =
      TextEditingController(text: widget.request.senderRaw ?? '');
  List<StudentCandidate> _matches = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  // Ambiguous (duplicate name) and unreliable senders must NOT persist the
  // extracted name as an alias — only a genuine new spelling (needs_review) is
  // safe to remember globally.
  bool get _canSaveAlias => widget.request.linkStatus == 'needs_review';
  bool get _canCreate =>
      widget.request.linkStatus != 'ambiguous' &&
      widget.request.linkStatus != 'unreliable_sender';

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
        _matches = matches;
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

  Future<void> _run(Future<void> Function() action) async {
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
        _error = 'Could not link this request. Please try again.';
      });
    }
  }

  void _linkTo(Student s) => _run(() => widget.databaseService
          .linkRequestToStudent(
        requestId: widget.request.id,
        studentId: s.id,
        canonicalName: s.name,
        aliasToSave: _canSaveAlias ? widget.request.senderRaw : null,
      ));

  void _createNew() => _run(() async {
        final created =
            await widget.databaseService.createStudent(_query.text.trim());
        await widget.databaseService.linkRequestToStudent(
          requestId: widget.request.id,
          studentId: created.id,
          canonicalName: created.name,
          aliasToSave: _canSaveAlias ? widget.request.senderRaw : null,
        );
      });

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final candidates = widget.students
        .where((s) => r.candidateStudentIds.contains(s.id))
        .toList();
    final sender = (r.senderRaw?.trim().isNotEmpty ?? false)
        ? r.senderRaw!.trim()
        : r.studentName;
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
            const Text('Resolve unclear student',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('WhatsApp sent this as “$sender”.',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
            if ((r.linkReason?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 4),
              Text(r.linkReason!,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],
            if (r.isAmbiguousSender) ...[
              const SizedBox(height: 10),
              const _NudgeTip(),
            ],
            if (candidates.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Likely matches',
                  style: TextStyle(
                      color: Colors.grey.shade700,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
              ...candidates.map((s) => _studentRow(
                    s,
                    subtitle: _subtitle(s),
                  )),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _query,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: 'Search all students',
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
            else if (_matches.isEmpty)
              Text('No matching students yet.',
                  style: TextStyle(color: Colors.grey.shade600))
            else
              ..._matches.map((c) => _studentRow(
                    c.student,
                    subtitle: c.reasonLabel,
                  )),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
            ],
            const Divider(height: 24),
            if (_canCreate)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_busy || _query.text.trim().isEmpty)
                      ? null
                      : _createNew,
                  icon: const Icon(Icons.person_add_alt),
                  label: Text(_query.text.trim().isEmpty
                      ? 'Enter a name to create a student'
                      : 'Create new student “${_query.text.trim()}”'),
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context, false),
                child: const Text('Leave unlinked / Not sure'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(Student s) {
    final parts = <String>[
      if (s.roomOrAddress.trim().isNotEmpty) s.roomOrAddress.trim(),
      if (s.phone.trim().isNotEmpty) s.phone.trim(),
      Student.statusLabel(s.status),
    ];
    return parts.join(' · ');
  }

  Widget _studentRow(Student s, {required String subtitle}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        child: Text(s.name.isEmpty ? '?' : s.name[0].toUpperCase()),
      ),
      title: Text(s.name,
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: TextButton(
        onPressed: _busy ? null : () => _linkTo(s),
        child: const Text('Link'),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.red.shade200),
          ),
          child: Text(message, style: TextStyle(color: Colors.red.shade700)),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
      ],
    );
  }
}
