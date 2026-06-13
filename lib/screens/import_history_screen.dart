import 'package:flutter/material.dart';

import '../models/chat_import.dart';
import '../services/database_service.dart';
import '../widgets/common.dart';
import 'import_detail_screen.dart';

/// Owner's past WhatsApp import runs (`chat_imports`). Pushed as a full route
/// from the Import tab so it doesn't add another bottom-nav item.
class ImportHistoryScreen extends StatefulWidget {
  const ImportHistoryScreen({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<ImportHistoryScreen> createState() => _ImportHistoryScreenState();
}

class _ImportHistoryScreenState extends State<ImportHistoryScreen> {
  bool _loading = true;
  String? _error;
  List<ChatImport> _imports = [];

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
      final rows = await widget.databaseService.fetchChatImports();
      if (!mounted) return;
      setState(() {
        _imports = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load import history. Pull to refresh.';
        _loading = false;
      });
    }
  }

  void _open(ChatImport imp) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImportDetailScreen(
          databaseService: widget.databaseService,
          chatImport: imp,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import history')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(message: _error!, onRetry: _load);
    }
    if (_imports.isEmpty) {
      // Keep pull-to-refresh available even when empty.
      return RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: const AppEmptyState(
                icon: Icons.history,
                title: 'No imports yet',
                message:
                    'Imported WhatsApp chats will show up here with their results.',
              ),
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _imports.length,
        itemBuilder: (_, i) =>
            _ImportCard(chatImport: _imports[i], onTap: () => _open(_imports[i])),
      ),
    );
  }
}

class _ImportCard extends StatelessWidget {
  const _ImportCard({required this.chatImport, required this.onTap});

  final ChatImport chatImport;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final imp = chatImport;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      imp.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ),
                  ImportStatusChip(status: imp.status, label: imp.statusLabel),
                  const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                formatStamp(imp.createdAt),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  InfoPill('${imp.totalMessages} messages'),
                  InfoPill('${imp.processedMessages} processed'),
                  if (imp.skippedOldMessages > 0)
                    InfoPill('${imp.skippedOldMessages} skipped (old)'),
                  InfoPill('${imp.extractedCount} extracted',
                      color: const Color(0xFF16A34A)),
                  if (imp.duplicateCount > 0)
                    InfoPill('${imp.duplicateCount} duplicates',
                        color: const Color(0xFFD97706)),
                  if (imp.rejectedCount > 0)
                    InfoPill('${imp.rejectedCount} needs review',
                        color: const Color(0xFF64748B)),
                ],
              ),
              if (imp.isFailed && (imp.errorMessage?.isNotEmpty ?? false)) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline,
                        size: 16, color: Colors.red.shade700),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        imp.errorMessage!,
                        style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small colored status chip shared by the history list and detail screen.
class ImportStatusChip extends StatelessWidget {
  const ImportStatusChip({super.key, required this.status, required this.label});

  final String status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'completed' => Colors.green,
      'processing' => Colors.blue,
      'uploaded' => Colors.blueGrey,
      'failed' => Colors.red,
      _ => Colors.grey,
    };
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 12, color: color.shade700, fontWeight: FontWeight.w700),
      ),
    );
  }
}
