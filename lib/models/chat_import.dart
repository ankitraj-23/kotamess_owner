/// Mirrors a row in `chat_imports` (migration 0008): one upload/import run.
///
/// The Edge Function `extract-requests` writes these rows server-side; the app
/// only reads them (owner-scoped) to render Import History. Kept as a thin,
/// forgiving mirror of the table, matching [MealRequest]'s style.
class ChatImport {
  final String id;
  final String source; // 'text_upload' | 'whatsapp_file' | 'paste' | ...
  final String? fileName;
  final String status; // 'uploaded' | 'processing' | 'completed' | 'failed'
  final int totalMessages;
  final int processedMessages;
  final int skippedOldMessages;
  final int extractedCount;
  final int duplicateCount;
  final int rejectedCount;
  final String? errorMessage;
  final DateTime? createdAt;
  final DateTime? importStartDate;
  final DateTime? importEndDate;

  ChatImport({
    required this.id,
    required this.source,
    required this.fileName,
    required this.status,
    required this.totalMessages,
    required this.processedMessages,
    required this.skippedOldMessages,
    required this.extractedCount,
    required this.duplicateCount,
    required this.rejectedCount,
    required this.errorMessage,
    required this.createdAt,
    this.importStartDate,
    this.importEndDate,
  });

  factory ChatImport.fromJson(Map<String, dynamic> json) {
    int asInt(String key) => (json[key] as num?)?.toInt() ?? 0;
    return ChatImport(
      id: json['id'] as String,
      source: json['source'] as String? ?? 'text_upload',
      fileName: json['file_name'] as String?,
      status: json['status'] as String? ?? 'uploaded',
      totalMessages: asInt('total_messages'),
      processedMessages: asInt('processed_messages'),
      skippedOldMessages: asInt('skipped_old_messages'),
      extractedCount: asInt('extracted_count'),
      duplicateCount: asInt('duplicate_count'),
      rejectedCount: asInt('rejected_count'),
      errorMessage: json['error_message'] as String?,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      importStartDate: DateTime.tryParse(json['import_start_date'] as String? ?? ''),
      importEndDate: DateTime.tryParse(json['import_end_date'] as String? ?? ''),
    );
  }

  bool get isFailed => status == 'failed';
  bool get isInProgress => status == 'uploaded' || status == 'processing';

  /// What to show as the import's headline (file name, else a source label).
  String get title {
    final name = fileName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return sourceLabel;
  }

  String get sourceLabel {
    switch (source) {
      case 'whatsapp_file':
        return 'WhatsApp file';
      case 'paste':
        return 'Pasted text';
      case 'file':
        return 'Uploaded file';
      case 'text_upload':
        return 'Text upload';
      default:
        return source;
    }
  }

  String get statusLabel {
    switch (status) {
      case 'completed':
        return 'Completed';
      case 'processing':
        return 'Processing';
      case 'uploaded':
        return 'Uploaded';
      case 'failed':
        return 'Failed';
      default:
        return status;
    }
  }
}
