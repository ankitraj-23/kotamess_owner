/// Mirrors a row in `imported_messages` — one row per import batch holds the
/// raw chat text the owner pasted or extracted from a WhatsApp export.
class ImportedMessage {
  final String id;
  final String ownerId;
  final String source; // 'paste' | 'whatsapp_file'
  final String rawText;
  final DateTime? importedAt;

  ImportedMessage({
    required this.id,
    required this.ownerId,
    required this.source,
    required this.rawText,
    required this.importedAt,
  });

  factory ImportedMessage.fromJson(Map<String, dynamic> json) {
    return ImportedMessage(
      id: json['id'] as String,
      ownerId: json['owner_id'] as String? ?? '',
      source: json['source'] as String? ?? 'paste',
      rawText: json['raw_text'] as String? ?? '',
      importedAt: DateTime.tryParse(json['imported_at'] as String? ?? ''),
    );
  }
}
