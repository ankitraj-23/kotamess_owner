/// Mirrors a row in `chat_messages` (migration 0008): one parsed message that
/// belongs to a `chat_imports` run. Read-only in the app (the Edge Function
/// writes them); used to show what an import actually parsed.
class ChatMessage {
  final String id;
  final String importId;
  final String? senderName;
  final String? senderPhone;
  final String messageText;
  final DateTime? messageTimestamp;
  final bool isCustomerMessage;
  final bool isProcessed;
  final DateTime? createdAt;

  ChatMessage({
    required this.id,
    required this.importId,
    required this.senderName,
    required this.senderPhone,
    required this.messageText,
    required this.messageTimestamp,
    required this.isCustomerMessage,
    required this.isProcessed,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      importId: json['import_id'] as String? ?? '',
      senderName: json['sender_name'] as String?,
      senderPhone: json['sender_phone'] as String?,
      messageText: json['message_text'] as String? ?? '',
      messageTimestamp:
          DateTime.tryParse(json['message_timestamp'] as String? ?? ''),
      isCustomerMessage: json['is_customer_message'] as bool? ?? true,
      isProcessed: json['is_processed'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
    );
  }

  String get senderLabel {
    final n = senderName?.trim();
    if (n != null && n.isNotEmpty) return n;
    final p = senderPhone?.trim();
    if (p != null && p.isNotEmpty) return p;
    return 'Unknown sender';
  }
}
