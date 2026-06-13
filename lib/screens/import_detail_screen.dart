import 'package:flutter/material.dart';

import '../models/chat_import.dart';
import '../models/chat_message.dart';
import '../models/meal_request.dart';
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

  final _requestsKey = GlobalKey();

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
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _messages = messages;
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
