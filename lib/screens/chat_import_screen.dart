import 'package:flutter/material.dart';

import '../models/extraction_result.dart';
import '../services/database_service.dart';
import '../services/extraction_service.dart';
import '../services/whatsapp_import.dart';
import 'import_history_screen.dart';

/// Import WhatsApp chat (paste / .txt / .zip) → the server parses it, extracts
/// requests, and saves them as pending `meal_requests`. The app just shows the
/// returned summary and sends the owner to the Requests screen to review.
class ChatImportScreen extends StatefulWidget {
  const ChatImportScreen({
    super.key,
    required this.extractionService,
    required this.databaseService,
    required this.onSavedGoToRequests,
  });

  final ExtractionService extractionService;
  final DatabaseService databaseService;
  final VoidCallback onSavedGoToRequests;

  @override
  State<ChatImportScreen> createState() => _ChatImportScreenState();
}

class _ChatImportScreenState extends State<ChatImportScreen> {
  final _input = TextEditingController();
  final _importer = const WhatsAppImporter();

  ImportedChat? _picked;
  bool _busy = false;
  ImportSummary? _summary;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool get _hasFile => _picked != null;

  Future<void> _pickFile() async {
    setState(() => _error = null);
    try {
      final chat = await _importer.pickAndRead();
      if (chat == null) return; // cancelled
      setState(() {
        _picked = chat;
        _input.text = chat.text;
        _summary = null;
      });
    } on ImportException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not import that file.');
    }
  }

  void _insertSample() {
    setState(() {
      _picked = null;
      _summary = null;
      _error = null;
      _input.text =
          '12/06/26, 8:10 pm - Ravi Sharma: kal lunch nahi chahiye\n'
          '12/06/26, 8:12 pm - Amit Verma: aaj dinner mat banana\n'
          '12/06/26, 8:15 pm - Neha Gupta: Sunday lunch add kar dena\n'
          '12/06/26, 8:20 pm - Pooja: kal se mess band\n'
          '12/06/26, 8:25 pm - Karan: monday se start kar dena\n'
          '12/06/26, 8:30 pm - Rohit: aaj dono meal cancel\n'
          '12/06/26, 8:32 pm - Sana: kitna due hai?\n'
          '12/06/26, 8:35 pm - Imran: payment bhej diya';
    });
  }

  void _clear() {
    setState(() {
      _input.clear();
      _picked = null;
      _summary = null;
      _error = null;
    });
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ImportHistoryScreen(databaseService: widget.databaseService),
      ),
    );
  }

  Future<void> _import() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Paste chat text or import a file first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _summary = null;
    });
    try {
      final summary = await widget.extractionService.importChat(
        chatText: text,
        source: _hasFile ? 'file' : 'paste',
        fileName: _picked?.fileName,
      );
      setState(() => _summary = summary);
    } on ExtractionException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Import failed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: ListTile(
            leading: const Icon(Icons.history),
            title: const Text('View import history'),
            subtitle: const Text('Past imports and the requests they extracted'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _openHistory,
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Import WhatsApp chat',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text(
                  'Upload WhatsApp .txt or .zip export, or paste the chat text. '
                  'Requests are extracted and saved on the server as pending '
                  'for your review.',
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _pickFile,
                      icon: const Icon(Icons.folder_zip_outlined),
                      label: const Text('Choose .txt or .zip'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _insertSample,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Insert sample'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _clear,
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear'),
                    ),
                  ],
                ),
                if (_picked != null) ...[
                  const SizedBox(height: 12),
                  _FileInfo(picked: _picked!),
                ],
                const SizedBox(height: 14),
                TextField(
                  controller: _input,
                  minLines: 6,
                  maxLines: 12,
                  decoration: InputDecoration(
                    hintText: 'Paste WhatsApp export text here…',
                    border:
                        OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.psychology_alt_outlined),
                    label: Text(_busy ? 'Importing…' : 'Import & extract'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(message: _error!),
        ],
        if (summary != null) ...[
          const SizedBox(height: 16),
          if (summary.usedFallback) _WarningBanner(warnings: summary.warnings),
          _SummaryCard(summary: summary),
          if (summary.extractedCount == 0)
            const _EmptyExtraction()
          else ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.onSavedGoToRequests,
                icon: const Icon(Icons.fact_check_outlined),
                label: Text('Review ${summary.extractedCount} request(s)'),
              ),
            ),
          ],
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final ImportSummary summary;
  const _SummaryCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Import summary',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            _SummaryRow('Total messages', summary.totalMessages),
            _SummaryRow('Processed messages', summary.processedMessages),
            _SummaryRow('Skipped (older than 90 days)', summary.skippedOldMessages),
            const Divider(height: 20),
            _SummaryRow('Extracted requests', summary.extractedCount,
                emphasize: true),
            _SummaryRow('Possible duplicates', summary.duplicateCount),
            _SummaryRow('Needs review (low confidence / unclear)',
                summary.rejectedCount),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final int value;
  final bool emphasize;
  const _SummaryRow(this.label, this.value, {this.emphasize = false});

  @override
  Widget build(BuildContext context) {
    final weight = emphasize ? FontWeight.w800 : FontWeight.w500;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(fontWeight: weight)),
          ),
          Text('$value',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ],
      ),
    );
  }
}

class _FileInfo extends StatelessWidget {
  final ImportedChat picked;
  const _FileInfo({required this.picked});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.description_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(picked.fileName,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                if (picked.innerFileName != null)
                  Text('Chat file: ${picked.innerFileName}',
                      style: TextStyle(
                          color: Colors.grey.shade700, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  final List<String> warnings;
  const _WarningBanner({required this.warnings});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.orange.shade800, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              warnings.isEmpty ? 'Used fallback parser.' : warnings.join(' '),
              style: TextStyle(color: Colors.orange.shade900),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: Colors.red.shade700)),
          ),
        ],
      ),
    );
  }
}

class _EmptyExtraction extends StatelessWidget {
  const _EmptyExtraction();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.search_off, size: 40, color: Colors.grey.shade600),
            const SizedBox(height: 8),
            const Text('No actionable requests found',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
              'Nothing in this chat looked like a mess request.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
