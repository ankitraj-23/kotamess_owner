import 'package:flutter/material.dart';

import '../models/extraction_result.dart';
import '../services/database_service.dart';
import '../services/extraction_service.dart';
import '../services/whatsapp_import.dart';
import '../widgets/confidence_badge.dart';

/// Import WhatsApp chat (paste / .txt / .zip) → extract via backend → save as
/// pending meal requests.
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
  bool _extracting = false;
  bool _saving = false;
  ExtractionResult? _result;
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
        _result = null;
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
      _result = null;
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
      _result = null;
      _error = null;
    });
  }

  Future<void> _extract() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Paste chat text or import a file first.');
      return;
    }
    setState(() {
      _extracting = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await widget.extractionService.extract(
        chatText: text,
        source: _hasFile ? 'file' : 'paste',
      );
      setState(() => _result = result);
    } on ExtractionException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Extraction failed. Please try again.');
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _save() async {
    final result = _result;
    if (result == null || result.requests.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final source = _hasFile ? 'file' : 'paste';
      final importId = await widget.databaseService.saveImportedMessage(
        rawText: _input.text.trim(),
        source: source,
      );
      final saved = await widget.databaseService.saveExtractedMealRequests(
        result.requests,
        source: source,
        importedMessageId: importId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${saved.length} pending request(s).')),
      );
      setState(() {
        _result = null;
        _input.clear();
        _picked = null;
      });
      widget.onSavedGoToRequests();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save requests. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
                  'Requests are extracted on the server and saved as pending '
                  'for your review.',
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _extracting || _saving ? null : _pickFile,
                      icon: const Icon(Icons.folder_zip_outlined),
                      label: const Text('Choose .txt or .zip'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _extracting || _saving ? null : _insertSample,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Insert sample'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _extracting || _saving ? null : _clear,
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
                    onPressed: _extracting || _saving ? null : _extract,
                    icon: _extracting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.psychology_alt_outlined),
                    label: Text(_extracting ? 'Extracting…' : 'Extract requests'),
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
        if (result != null) ...[
          const SizedBox(height: 16),
          if (result.usedFallback) _WarningBanner(warnings: result.warnings),
          if (result.requests.isEmpty)
            const _EmptyExtraction()
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Extracted ${result.requests.length}',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...result.requests.map((r) => _ExtractedCard(request: r)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  _saving
                      ? 'Saving…'
                      : 'Save ${result.requests.length} as pending requests',
                ),
              ),
            ),
          ],
        ],
        const SizedBox(height: 24),
      ],
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

class _ExtractedCard extends StatelessWidget {
  final ExtractedRequest request;
  const _ExtractedCard({required this.request});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(request.studentName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                ConfidenceBadge(confidence: request.confidence),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _Tag(request.requestTypeLabel),
                if (request.mealType != 'none') _Tag(request.mealTypeLabel),
                _Tag(request.requestDate ?? request.dateLabel),
              ],
            ),
            const SizedBox(height: 8),
            Text('“${request.originalMessage}”',
                style: TextStyle(color: Colors.grey.shade800)),
            if (request.reason.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(request.reason,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
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
